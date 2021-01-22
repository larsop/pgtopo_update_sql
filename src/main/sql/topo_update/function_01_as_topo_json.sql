-- This is mod of the orginal function to Sandro Santilli <strk@kbt.io>  to handle bb to reduce the size of data.
--
-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
--
-- PostGIS - Spatial Types for PostgreSQL
-- http://postgis.net
--
-- Copyright (C) 2013-2020 Sandro Santilli <strk@kbt.io> 
--
-- This is free software; you can redistribute and/or modify it under
-- the terms of the GNU General Public Licence. See the COPYING file.
--
-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
--
-- Functions used for TopoJSON export
--
-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

/* #define POSTGIS_TOPOLOGY_DEBUG 1 */

--{
--
-- API FUNCTION
--
-- text AsTopoJSON(TopoGeometry, edgeMapTable, BoundingBox)
-- 
-- Format specification here:
-- http://github.com/mbostock/topojson-specification/blob/master/README.md
--
-- }{
-- if bb is not null this function will remove holes composed by a single edge that are outside given bouding box

drop function if exists topo_update.as_topo_json(tg topology.TopoGeometry, edgeMapTable regclass, bb geometry);
 
CREATE OR REPLACE FUNCTION topo_update.as_topo_json(tg topology.TopoGeometry, edgeMapTable regclass, bb geometry)
  RETURNS text AS
$$
DECLARE
  toponame text;
  json text;
  sql text;
  rec RECORD;
  rec2 RECORD;
  side int;
  arcid int;
  arcs int[];
  arcs_boandary text[];
  arcs_holes int[];
  existing_edge_ids int[];
  ringtxt TEXT[];
  comptxt TEXT[];
  edges_found BOOLEAN;
  old_search_path TEXT;
  all_faces int[];
  faces int[];
  shell_faces int[];
  visited_edges int[];
  looking_for_holes BOOLEAN;
  cmd text; -- used hold commands to run
  mbr_box geometry;-- holds the mbr geometry
  bb_intersect_mbr geometry; -- used to hold the intersection beetwenn the mbr and bb
  stop_index_closed_ring int;
  start_index_closed_ring int;
  geo_outer_boandary geometry;
  face_id_selcted int;
  has_valid_holes boolean;
  has_valid_boundary boolean;
  has_valid_data boolean ;
  point_reduction boolean = false;
  closed_ring_number int;
  json_row_number int;
  json_data_found boolean = false;
  
  
BEGIN

  IF tg IS NULL THEN
    RETURN NULL;
  END IF;

  -- Get topology name (for subsequent queries)
  SELECT name FROM topology.topology into toponame
              WHERE id = tg.topology_id;

  -- TODO: implement scale ?

  -- Puntal TopoGeometry, simply delegate to AsGeoJSON
  IF tg.type = 1 THEN
    json := ST_AsGeoJSON(topology.Geometry(tg));
    return json;
  ELSIF tg.type = 2 THEN -- lineal

    FOR rec IN SELECT (ST_Dump(topology.Geometry(tg))).geom
    LOOP -- {

      sql := 'SELECT e.*, ST_LineLocatePoint($1'
            || ', ST_LineInterpolatePoint(e.geom, 0.2)) as pos'
            || ', ST_LineLocatePoint($1'
            || ', ST_LineInterpolatePoint(e.geom, 0.8)) as pos2 FROM '
            || quote_ident(toponame)
            || '.edge e WHERE ST_Covers($1'
            || ', e.geom) ORDER BY pos';
            -- TODO: add relation to the conditional, to reduce load ?
      FOR rec2 IN EXECUTE sql USING rec.geom
      LOOP -- {

        IF edgeMapTable IS NOT NULL THEN
          sql := 'SELECT arc_id-1 FROM ' || edgeMapTable::text || ' WHERE edge_id = $1';
          EXECUTE sql INTO arcid USING rec2.edge_id;
          IF arcid IS NULL THEN
            EXECUTE 'INSERT INTO ' || edgeMapTable::text
              || '(edge_id) VALUES ($1) RETURNING arc_id-1'
            INTO arcid USING rec2.edge_id;
          END IF;
        ELSE
          arcid := rec2.edge_id;
        END IF;

        -- edge goes in opposite direction
        IF rec2.pos2 < rec2.pos THEN
          arcid := -(arcid+1);
        END IF;

        arcs := arcs || arcid;

      END LOOP; -- }

      comptxt := comptxt || ( '[' || array_to_string(arcs, ',') || ']' );
      arcs := NULL;

    END LOOP; -- }

    json := '{ "type": "MultiLineString", "arcs": [' || array_to_string(comptxt,',') || ']}';

    return json;

  ELSIF tg.type = 3 THEN -- areal

    json := '{ "type": "MultiPolygon", "arcs": [';

    EXECUTE 'SHOW search_path' INTO old_search_path;
    EXECUTE 'SET search_path TO ' || quote_ident(toponame) || ',' || old_search_path;

    SELECT array_agg(id) as f
    FROM ( SELECT (topology.GetTopoGeomElements(tg))[1] as id ) as f
    INTO all_faces;
    
--    all_faces := '{3}';

--#ifdef POSTGIS_TOPOLOGY_DEBUG
    RAISE DEBUG 'Faces: %', all_faces;
--#endif

    visited_edges := ARRAY[]::int[];
    faces := all_faces;
    looking_for_holes := false;
    shell_faces := ARRAY[]::int[];

-- Test this
--Koordinater (meter) i UTM-sone 32
--Nord, Øst: [ 6555265, 350075 ]

    IF bb IS NULL THEN -- get all edges for given topology
      CREATE TEMP TABLE _postgis_topology_astopojson_tmp_edges
      ON COMMIT DROP
      AS
      SELECT
           ROW_NUMBER() OVER (
              ORDER BY
                ST_XMin(e.geom),
                ST_YMin(e.geom),
                edge_id
           ) leftmost_index,
           e.edge_id,
           e.left_face,
           e.right_face,
           e.next_right_edge,
           e.next_left_edge,
           e.geom
      FROM edge_data e
      WHERE
           ( e.left_face = ANY ( all_faces ) OR
             e.right_face = ANY ( all_faces ) );
             
      --RAISE NOTICE 'case no bb _postgis_topology_astopojson_tmp_edges % for all_faces %', (select count(*) from _postgis_topology_astopojson_tmp_edges),all_faces;
             
    ELSE -- Use bb (bounding box) as to remove holes with a single edge outside the bounding box 
      -- Will not pick up  edges where left_face = right_face
           
      point_reduction = true;
      json_row_number = 0;

      -- find the mbr for selected faces  
      FOREACH face_id_selcted IN ARRAY all_faces
      LOOP -- { until faces are done
        cmd := Format('SELECT f.mbr FROM  %1$s.face f WHERE f.face_id = %2$s',toponame,face_id_selcted);
        EXECUTE cmd INTO mbr_box;
        
        start_index_closed_ring = 1;
        
        -- find intersection beetween th bb and mbr
        bb_intersect_mbr = ST_Intersection(mbr_box,bb);
        -- TODO what should here if we get null here,  Should we return a empty TopoJSON ??
                
        cmd := Format('CREATE TEMP TABLE _astopojson_with_bb_all_edges ON COMMIT DROP AS
        SELECT r.*
        FROM (
          SELECT 
          fe.sequence,
          fe.edge as signed_edge_id_fa, 
          e.*,

          --CASE WHEN e.left_face = %2$s THEN e.right_face ELSE e.left_face END AS other_face,

          CASE WHEN fe.edge < 0 THEN e.end_node
          ELSE e.start_node
          END
          AS logical_start_node,

          CASE WHEN fe.edge < 0 THEN e.start_node
          ELSE e.end_node
          END
          AS logical_end_node, 

          CASE WHEN e.geom && %3$L THEN TRUE
          ELSE FALSE
          END
          AS mbr_intersect 
     
          FROM
            (SELECT sequence, edge, abs(edge) as edge_id_abs 
              FROM 
              (SELECT (topology.ST_GetFaceEdges(%1$L, %2$s)).*) as foo
            ) as fe
          LEFT JOIN %1$s.edge_data e ON e.edge_id = fe.edge_id_abs 
        ) AS r
        ORDER BY sequence',
        toponame,
        face_id_selcted,
        bb_intersect_mbr);
        EXECUTE cmd;

--        RAISE NOTICE 'cmd %',cmd;
    
        CREATE UNIQUE INDEX ON _astopojson_with_bb_all_edges (sequence);
        CREATE INDEX ON _astopojson_with_bb_all_edges (logical_start_node);
        CREATE INDEX ON _astopojson_with_bb_all_edges (logical_end_node);
        CREATE INDEX ON _astopojson_with_bb_all_edges (edge_id);
        CREATE INDEX ON _astopojson_with_bb_all_edges (signed_edge_id_fa);
        ANALYZE _astopojson_with_bb_all_edges;

        closed_ring_number := 0;
        
        <<inner_loop>>
        loop -- start loop outer ring and internal rings
        
          -- find stop index
          cmd := Format('SELECT l2.sequence 
          FROM 
          _astopojson_with_bb_all_edges l1,
          _astopojson_with_bb_all_edges l2
          WHERE l1.sequence = %1$s AND l2.sequence >= %1$s AND
          l1.logical_start_node = l2.logical_end_node',
          start_index_closed_ring);
          EXECUTE cmd INTO stop_index_closed_ring;

          -- if no new data
          exit when stop_index_closed_ring is null;
          
          RAISE NOTICE 'start_index_closed_ring % stop_index_closed_ring %',start_index_closed_ring, stop_index_closed_ring;
          
          -- check if valid data here, inside bb
          has_valid_data = false;
          
          IF closed_ring_number = 0 THEN
            cmd := Format('SELECT ST_Polygonize(geom) FROM _astopojson_with_bb_all_edges e WHERE e.sequence >= %1$s AND e.sequence <= %2$s',
            start_index_closed_ring,
            stop_index_closed_ring);
            EXECUTE cmd INTO geo_outer_boandary;
            IF (ST_Intersects(bb_intersect_mbr,geo_outer_boandary)) THEN
              has_valid_data = true;
              json_data_found = true;
            ELSE
              -- exit no data in first loop
              exit when closed_ring_number = 0 ;
            END IF;
          ELSE
            cmd := Format('SELECT TRUE FROM _astopojson_with_bb_all_edges e WHERE e.sequence >= %1$s AND e.sequence <= %2$s AND mbr_intersect limit 1',
            start_index_closed_ring,
            stop_index_closed_ring);
            EXECUTE cmd INTO has_valid_data;
          END IF;

          -- if inside data
          IF has_valid_data THEN
            closed_ring_number := closed_ring_number + 1;
          
            IF edgeMapTable IS NOT NULL THEN
  
              cmd := Format('select array_agg(edge_id) FROM %1$s', edgeMapTable::text);
              EXECUTE cmd INTO existing_edge_ids;
              
              IF existing_edge_ids IS NULL THEN 
                existing_edge_ids :=  ARRAY[]::int[];
              END IF;
              
              cmd := Format('INSERT INTO %1$s(edge_id--,arc
              ,signed_edge_id_fa,geom)
              SELECT 
                 e.edge_id AS edge_id, 
                 --''[[''||ST_X(ST_StartPoint(e.geom))||'',''||ST_Y(ST_EndPoint(e.geom))||'']]'' as arc,
                 e.signed_edge_id_fa,
                 e.geom
                 FROM (SELECT DISTINCT ON (bb.edge_id) bb.edge_id, bb.signed_edge_id_fa, bb.sequence, bb.geom
                       FROM  
                       _astopojson_with_bb_all_edges bb
                       WHERE bb.sequence >= %3$s AND bb.sequence <= %4$s AND NOT (bb.edge_id = ANY (%2$L))
                 ) e ORDER BY e.sequence desc', 
              edgeMapTable::text, 
              existing_edge_ids,
              start_index_closed_ring,
              stop_index_closed_ring);
              EXECUTE cmd;
              
              cmd := Format('SELECT array_agg(e.arc_id ORDER BY e.sequence desc)  
                 FROM (
                 SELECT DISTINCT ON (e.edge_id)
                 CASE WHEN e.signed_edge_id_fa > 0 THEN (-1*r.arc_id) ELSE (r.arc_id-1) END as arc_id , 
                 e.sequence
                 FROM _astopojson_with_bb_all_edges e, %s r 
                 WHERE e.sequence >= %2$s AND e.sequence <= %3$s AND r.edge_id = e.edge_id
              ) as e',
              edgeMapTable::text,
              start_index_closed_ring,
              stop_index_closed_ring);
              EXECUTE cmd into arcs_boandary;
              
              --RAISE NOTICE 'arcs_boandary %, face_id_selcted % ', arcs_boandary, face_id_selcted;
  
            ELSE
              -- TODO fix/check this code
              cmd := Format('SELECT array_agg(e.signed_edge_id_fa ORDER BY e.sequence desc) 
              FROM (
                SELECT * FROM ( SELECT DISTINCT ON ( edge_id) 
                  signed_edge_id_fa, 
                  sequence
                      FROM  FROM _astopojson_with_bb_all_edges e WHERE e.sequence >= %2$s AND e.sequence <= %3$
                ) e ORDER BY sequence',
                 start_index_closed_ring,
                 stop_index_closed_ring);
              EXECUTE cmd into arcs_boandary;
            END IF;
  
            -- add outer ring
            IF closed_ring_number = 1 THEN 
              IF json_row_number > 0 THEN 
                json := json||',';
              END IF;
              json := json||'[[' || array_to_string(arcs_boandary,',') || ']' ;   
            ELSE
              IF closed_ring_number > 1 THEN 
                json := json||',';
              END IF;
              json := json||'[' || array_to_string(arcs_boandary,',') || ']' ;   
            END IF;
          END IF; -- end has data
  
          start_index_closed_ring = stop_index_closed_ring + 1;
          stop_index_closed_ring = null;
          
        END loop inner_loop;
        
        json_row_number := json_row_number + 1;
        
        IF closed_ring_number > 0 THEN 
          json := json||']';
        END IF;
          

        DROP table _astopojson_with_bb_all_edges;

        
      END LOOP;
        
      --RAISE NOTICE 'stop_index_closed_ring %,  has_valid_holes % geo_outer_boandary % all_faces %, bb_intersect_mbr % face_id_selcted %', stop_index_closed_ring, has_valid_holes, geo_outer_boandary, all_faces, bb_intersect_mbr, face_id_selcted;
      
      IF json_data_found THEN
        json := json||']}';
      ELSE
        json := NULL; -- bo data found
      END IF;
     
        RETURN json; -- we are done
        EXECUTE 'SET search_path TO ' || old_search_path;
    
      
      --RAISE NOTICE 'case bb _postgis_topology_astopojson_tmp_edges % for all_faces %', (select count(*) from _postgis_topology_astopojson_tmp_edges),all_faces;
        

      --RAISE NOTICE 'json % for all_faces %', json,all_faces;

      --RAISE NOTICE 'case bb _postgis_topology_astopojson_tmp_edges % for all_faces %', (select count(*) from _postgis_topology_astopojson_tmp_edges),all_faces;
  
    END IF;
   
     
    CREATE INDEX on _postgis_topology_astopojson_tmp_edges (edge_id);
    CREATE INDEX on _postgis_topology_astopojson_tmp_edges (leftmost_index);

--    RAISE NOTICE 'Testlog Check edge for all_faces % with point_reduction %', all_faces, point_reduction;
--    FOR rec IN SELECT * FROM _postgis_topology_astopojson_tmp_edges
--    LOOP
--      RAISE NOTICE 'Testlog rec.edge_id % e.left_face % e.right_face % e.geom % for % with point_reduction %', rec.edge_id, rec.left_face, rec.right_face, rec.geom, all_faces, point_reduction;
--    END LOOP;

    
    LOOP -- { until all edges were visited

      arcs := NULL;
      edges_found := false;

--#ifdef POSTGIS_TOPOLOGY_DEBUG
      RAISE DEBUG 'LOOP START - looking for next % binding faces %',
        CASE WHEN looking_for_holes THEN 'hole' ELSE 'shell' END, faces;
--#endif

      FOR rec in -- {
WITH RECURSIVE
_edges AS (
  SELECT
     *,
     left_face = ANY ( faces ) as lf,
     right_face = ANY ( faces ) as rf
  FROM
    _postgis_topology_astopojson_tmp_edges
),
_leftmost_non_dangling_edge AS (
  SELECT e.edge_id
    FROM _edges e WHERE e.lf != e.rf
  ORDER BY
    leftmost_index
  LIMIT 1
),
_edgepath AS (
  SELECT
    CASE
      WHEN e.lf THEN lme.edge_id
      ELSE -lme.edge_id
    END as signed_edge_id,
    false as back,

    e.lf = e.rf as dangling,
    e.left_face, e.right_face,
    e.lf, e.rf,
    e.next_right_edge, e.next_left_edge

  FROM _edges e, _leftmost_non_dangling_edge lme
  WHERE e.edge_id = abs(lme.edge_id)
    UNION
  SELECT
    CASE
      WHEN p.dangling AND NOT p.back THEN -p.signed_edge_id
      WHEN p.signed_edge_id < 0 THEN p.next_right_edge
      ELSE p.next_left_edge
    END, -- signed_edge_id
    CASE
      WHEN p.dangling AND NOT p.back THEN true
      ELSE false
    END, -- back

    e.lf = e.rf, -- dangling
    e.left_face, e.right_face,
    e.lf, e.rf,
    e.next_right_edge, e.next_left_edge

  FROM _edges e, _edgepath p
  WHERE
    e.edge_id = CASE
      WHEN p.dangling AND NOT p.back THEN abs(p.signed_edge_id)
      WHEN p.signed_edge_id < 0 THEN abs(p.next_right_edge)
      ELSE abs(p.next_left_edge)
    END
)
SELECT abs(signed_edge_id) as edge_id, signed_edge_id, dangling,
        lf, rf, left_face, right_face
FROM _edgepath
      -- }

      LOOP  -- { over recursive query

--#ifdef POSTGIS_TOPOLOGY_DEBUG
        RAISE DEBUG ' edge % lf:%(%) rf:%(%)' , rec.signed_edge_id, rec.lf, rec.left_face, rec.rf, rec.right_face;
--#endif

        IF rec.left_face = ANY (all_faces) AND NOT rec.left_face = ANY (shell_faces) THEN
          shell_faces := shell_faces || rec.left_face;
        END IF;

        IF rec.right_face = ANY (all_faces) AND NOT rec.right_face = ANY (shell_faces) THEN
          shell_faces := shell_faces || rec.right_face;
        END IF;

        visited_edges := visited_edges || rec.edge_id;

        edges_found := true;

        -- TODO: drop ?
        IF rec.dangling THEN
          CONTINUE;
        END IF;

        IF rec.left_face = ANY (all_faces) AND rec.right_face = ANY (all_faces) THEN
          CONTINUE;
        END IF;

        IF edgeMapTable IS NOT NULL THEN
          sql := 'SELECT arc_id-1 FROM ' || edgeMapTable::text || ' WHERE edge_id = $1';
          EXECUTE sql INTO arcid USING rec.edge_id;
          IF arcid IS NULL THEN
            EXECUTE 'INSERT INTO ' || edgeMapTable::text
              || '(edge_id) VALUES ($1) RETURNING arc_id-1'
            INTO arcid USING rec.edge_id;
          END IF;
        ELSE
          arcid := rec.edge_id-1;
        END IF;

        -- Swap sign, use two's complement for negative edges
        IF rec.signed_edge_id >= 0 THEN
          arcid := - ( arcid + 1 );
        END IF;

--#ifdef POSTGIS_TOPOLOGY_DEBUG
        RAISE DEBUG 'ARC id: %' , arcid;
--#endif

        arcs := arcid || arcs;

      END LOOP; -- } over recursive query

      DELETE from _postgis_topology_astopojson_tmp_edges
      WHERE edge_id = ANY (visited_edges);
      visited_edges := ARRAY[]::int[];

--#ifdef POSTGIS_TOPOLOGY_DEBUG
      --RAISE DEBUG 'Edges found:%, visited faces: %, ARCS: %' , edges_found, shell_faces, arcs;
--#endif

      IF NOT edges_found THEN -- {

        IF looking_for_holes THEN
          looking_for_holes := false;
--#ifdef POSTGIS_TOPOLOGY_DEBUG
          RAISE DEBUG 'NO MORE holes, rings:%', ringtxt;
--#endif
          comptxt := comptxt || ( '[' || array_to_string(ringtxt, ',') || ']' );
          ringtxt := NULL;
          faces := all_faces;
          shell_faces := ARRAY[]::int[];
        ELSE
          EXIT; -- end of loop
        END IF;

      ELSE -- } edges found {

        faces := shell_faces;
        IF arcs IS NOT NULL THEN
--#ifdef POSTGIS_TOPOLOGY_DEBUG
          RAISE DEBUG ' % arcs: %', CASE WHEN looking_for_holes THEN 'hole' ELSE 'shell' END, arcs;
--#endif
          ringtxt := ringtxt || ( '[' || array_to_string(arcs,',') || ']' );
        END IF;
        looking_for_holes := true;

      END IF; -- }

    END LOOP; -- }

    DROP TABLE _postgis_topology_astopojson_tmp_edges;

    json := json || array_to_string(comptxt, ',') || ']}';
    
    RAISE NOTICE 'json % for all_faces % , %', json,all_faces, ST_asText(bb);
    

    EXECUTE 'SET search_path TO ' || old_search_path;

  ELSIF tg.type = 4 THEN -- collection
    RAISE EXCEPTION 'Collection TopoGeometries are not supported by AsTopoJSON';

  END IF;

  RETURN json;

END
$$ LANGUAGE 'plpgsql' VOLATILE; -- writes into visited table
-- } AsTopoJSON(TopoGeometry, visited_table)

