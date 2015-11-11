-- This a function that will be called from the client when user is drawing a line
-- This line will be applied the data in the line layer

-- The result is a set of id's of the new line objects created

-- TODO set attributtes for the line


CREATE OR REPLACE FUNCTION topo_update.create_line_edge_domain_obj(json_feature text) 
RETURNS TABLE(id integer) AS $$
DECLARE

json_result text;

new_border_data topogeometry;

-- this border layer id will picked up by input parameters
border_layer_id int;

-- this is the tolerance used for snap to 
snap_tolerance float8 = 0.0000000001;

-- TODO use as parameter put for testing we just have here for now
border_topo_info topo_update.input_meta_info ;

-- hold striped gei
edge_with_out_loose_ends geometry = null;

-- holds dynamic sql to be able to use the same code for different
command_string text;

-- used for logging
num_rows_affected int;

-- used for logging
add_debug_tables int = 0;

-- the number times the inlut line intersects
num_edge_intersects int;

input_geo geometry;

-- holds the value for felles egenskaper from input
felles_egenskaper_linje topo_rein.sosi_felles_egenskaper;
simple_sosi_felles_egenskaper_linje topo_rein.simple_sosi_felles_egenskaper;

BEGIN
	
	
	-- TODO to be moved is justed for testing now
	border_topo_info.topology_name := 'topo_rein_sysdata';
	border_topo_info.layer_schema_name := 'topo_rein';
	border_topo_info.layer_table_name := 'reindrift_anlegg_linje';
	border_topo_info.layer_feature_column := 'linje';
	border_topo_info.snap_tolerance := 0.0000000001;
	border_topo_info.element_type = 2;
	
		-- find border layer id
	border_layer_id := topo_update.get_topo_layer_id(border_topo_info);

	
	RAISE NOTICE 'The JSON input %',  json_feature;

	RAISE NOTICE 'border_layer_id %',  border_layer_id;


	-- get the json values
	DROP TABLE IF EXISTS topo_rein.ttt_new_attributes_values;
	CREATE TABLE topo_rein.ttt_new_attributes_values(geom geometry,properties json);
	INSERT INTO topo_rein.ttt_new_attributes_values(geom,properties)
	SELECT 
		topo_rein.get_geom_from_json(feat,4258) as geom,
		to_json(feat->'properties')::json  as properties
	FROM (
	  	SELECT json_feature::json AS feat
	) AS f;

		-- check that it is only one row put that value into 
	-- TODO rewrite this to not use table in
	
	IF (SELECT count(*) FROM topo_rein.ttt_new_attributes_values) != 1 THEN
		RAISE EXCEPTION 'Not valid json_feature %', json_feature;
	ELSE 
		-- TODO find another way to handle this
		SELECT * INTO simple_sosi_felles_egenskaper_linje 
		FROM json_populate_record(NULL::topo_rein.simple_sosi_felles_egenskaper,
		(select properties from topo_rein.ttt_new_attributes_values) );

		felles_egenskaper_linje := topo_rein.get_rein_felles_egenskaper(simple_sosi_felles_egenskaper_linje);
	
		SELECT geom INTO input_geo FROM topo_rein.ttt_new_attributes_values;
	
	END IF;

	-- insert the data in the org table and keep a copy of the data
	DROP TABLE IF EXISTS topo_rein.ttt_rows_affected_in_org_table;
	CREATE TABLE topo_rein.ttt_rows_affected_in_org_table AS (SELECT * FROM  topo_rein.reindrift_anlegg_linje limit 0);
	WITH inserted AS (
		INSERT INTO topo_rein.reindrift_anlegg_linje(linje, felles_egenskaper, reindriftsanleggstype,reinbeitebruker_id)
		SELECT  
			topology.toTopoGeom(t2.geom, border_topo_info.topology_name, border_layer_id, border_topo_info.snap_tolerance) AS linje,
			felles_egenskaper_linje AS felles_egenskaper,
			(t2.properties->>'reindriftsanleggstype')::int AS reindriftsanleggstype,
			(t2.properties->>'reinbeitebruker_id')::text AS reinbeitebruker_id
		FROM topo_rein.ttt_new_attributes_values t2
		RETURNING *
	)
	INSERT INTO topo_rein.ttt_rows_affected_in_org_table
	SELECT * FROM inserted;

	--------------------- Start: code to remove duplicate edges ---------------------
	-- Should be moved to a separate proc so we could reuse this code for other line 
	
	-- Find the edges that are used by the input line
	DROP TABLE IF EXISTS topo_rein.ttt_covered_by_input_line;
	CREATE TABLE topo_rein.ttt_covered_by_input_line AS (SELECT ed.* FROM  topo_rein_sysdata.edge_data ed limit 0);
	INSERT INTO topo_rein.ttt_covered_by_input_line
	SELECT distinct ed.*  
    FROM 
	topo_rein_sysdata.relation re,
	topo_rein.ttt_rows_affected_in_org_table ud, 
	topo_rein_sysdata.edge_data ed
	WHERE 
	(ud.linje).id = re.topogeo_id AND
	re.layer_id =  border_layer_id AND 
	re.element_type = 2 AND  -- TODO use variable element_type_edge=2
	ed.edge_id = re.element_id;

	-- Find edges that are not used by the input line which needs to recreated
	DROP TABLE IF EXISTS topo_rein.ttt_not_covered_by_input_line;
	CREATE TABLE topo_rein.ttt_not_covered_by_input_line AS (SELECT ed.* FROM  topo_rein_sysdata.edge_data ed limit 0);
	INSERT INTO topo_rein.ttt_not_covered_by_input_line
	SELECT distinct ed.*  
    FROM 
	topo_rein_sysdata.relation re,
	topo_rein.ttt_rows_affected_in_org_table ud, 
	topo_rein_sysdata.edge_data ed
	WHERE 
	(ud.linje).id = re.topogeo_id AND
	re.layer_id =  border_layer_id AND 
	re.element_type = 2 AND  -- TODO use variable element_type_edge=2
	ed.edge_id != re.element_id  AND
	NOT EXISTS (SELECT 1 FROM topo_rein.ttt_covered_by_input_line t WHERE t.edge_id = ed.edge_id);

	-- Find anleggs type objects that needs to be adjusted because the new rows has edges that are used by this rows
	DROP TABLE IF EXISTS topo_rein.ttt_affected_objects_id;
	CREATE TABLE topo_rein.ttt_affected_objects_id AS (SELECT * FROM  topo_rein.reindrift_anlegg_linje limit 0);
	INSERT INTO topo_rein.ttt_affected_objects_id
	SELECT distinct a.*  
    FROM 
	topo_rein_sysdata.relation re1,
	topo_rein_sysdata.relation re2,
	topo_rein.ttt_rows_affected_in_org_table ud, 
	topo_rein_sysdata.edge_data ed,
	topo_rein.reindrift_anlegg_linje a
	WHERE 
	(ud.linje).id = re1.topogeo_id AND
	re1.layer_id =  border_layer_id AND 
	re1.element_type = 2 AND
	(ud.linje).id = re2.topogeo_id AND
	re2.layer_id =  border_layer_id AND 
	re2.element_type = 2 AND
	NOT EXISTS (SELECT 1 FROM topo_rein.ttt_rows_affected_in_org_table nr where a.id = nr.id);
	
	-- Find objects thay can deleted because all their edges area covered by new input linje
	-- This is true this objects has no edges in the list of not used edges
	DROP TABLE IF EXISTS topo_rein.ttt_objects_to_be_delted;
	CREATE TABLE topo_rein.ttt_objects_to_be_delted AS (SELECT * FROM  topo_rein.reindrift_anlegg_linje limit 0);
	INSERT INTO topo_rein.ttt_objects_to_be_delted
	SELECT b.id FROM 
	topo_rein.ttt_affected_objects_id b
	WHERE b.id NOT IN
	(	
		SELECT distinct a.id 
		FROM 
		topo_rein_sysdata.relation re1,
		topo_rein.ttt_affected_objects_id a,
		topo_rein.ttt_not_covered_by_input_line ued1
		WHERE 
		(a.linje).id = re1.topogeo_id AND
		re1.layer_id =  border_layer_id AND 
		re1.element_type = 2 AND
		ued1.edge_id = re1.element_id
	); 

	-- Clear the topology elements objects that does not have edges left
	PERFORM topology.clearTopoGeom(a.linje) 
	FROM topo_rein.reindrift_anlegg_linje  a,
	topo_rein.ttt_objects_to_be_delted b
	WHERE a.id = b.id;
	
	-- Delete those topology elements objects that does not have edges left
	DELETE FROM topo_rein.reindrift_anlegg_linje a
	USING topo_rein.ttt_objects_to_be_delted b
	WHERE a.id = b.id;

	-- Find  lines that shoul be added again the which object they belong to
	DROP TABLE IF EXISTS topo_rein.ttt_objects_to_be_updated;
	CREATE TABLE topo_rein.ttt_objects_to_be_updated(id int, geom geometry);
	INSERT INTO topo_rein.ttt_objects_to_be_updated(id,geom)
	SELECT b.id, ST_union(ed.geom) AS geom
	FROM topo_rein.ttt_affected_objects_id b,
	topo_rein.ttt_not_covered_by_input_line ed,
	topo_rein_sysdata.relation re
	WHERE (b.linje).id = re.topogeo_id AND
	re.layer_id =  border_layer_id AND 
	re.element_type = 2 AND  -- TODO use variable element_type_edge=2
	ed.edge_id != re.element_id
	GROUP BY b.id;

	-- Clear the topology elements objects that should be updated
	PERFORM topology.clearTopoGeom(a.linje) 
	FROM topo_rein.reindrift_anlegg_linje  a,
	topo_rein.ttt_objects_to_be_updated b
	WHERE a.id = b.id;
	
	-- Update the topo objects with shared edges that stil hava 
	UPDATE topo_rein.reindrift_anlegg_linje AS a
	SET linje= topology.toTopoGeom(b.geom, border_topo_info.topology_name, border_layer_id, border_topo_info.snap_tolerance)
	FROM topo_rein.ttt_objects_to_be_updated b
	WHERE a.id = b.id;

	-- We have now removed duplicate ref to any edges, this means that each edge is only used once
	--------------------- Stop: code to remove duplicate edges ---------------------

	
	-- Find rows that intersects with the new line drawn by the end user
	-- This lines should be returned to affected together with the line created
	DROP TABLE IF EXISTS ttt_intersection_id;
	CREATE TEMP TABLE ttt_intersection_id AS (SELECT * FROM  topo_rein.reindrift_anlegg_linje limit 0);
	INSERT INTO ttt_intersection_id
	SELECT distinct a.*  
	FROM 
	topo_rein.reindrift_anlegg_linje a, 
	topo_rein.ttt_new_attributes_values a2,
	topo_rein_sysdata.relation re, 
	topology.layer tl,
	topo_rein_sysdata.edge ed
	WHERE ST_intersects(ed.geom,a2.geom)
	AND topo_rein.get_relation_id(a.linje) = re.topogeo_id AND re.layer_id = tl.layer_id AND tl.schema_name = 'topo_rein' AND 
	tl.table_name = 'reindrift_anlegg_linje' AND ed.edge_id=re.element_id
	AND NOT EXISTS (SELECT 1 FROM topo_rein.ttt_rows_affected_in_org_table nr where a.id = nr.id);

	-- update the return table with 
	INSERT INTO topo_rein.ttt_rows_affected_in_org_table(id)
	SELECT a.id FROM ttt_intersection_id a ;

	GET DIAGNOSTICS num_rows_affected = ROW_COUNT;
	RAISE NOTICE 'Number num_rows_affected  %',  num_rows_affected;
	
	
	--------------------- Start: Find short eges to be removed  ---------------------
	-- Should be moved to a separate proc so we could reuse this code for other line 
	
	-- Find edges that are verry short and that are close to the edges that area drawn.
	-- Find the edges that are used by the input line
	
	DROP TABLE IF EXISTS topo_rein.ttt_short_edge_list;
	CREATE TABLE topo_rein.ttt_short_edge_list(id int, edge_id int);
	INSERT INTO topo_rein.ttt_short_edge_list(id,edge_id)
	SELECT distinct a.id, ed.edge_id  
    FROM 
	topo_rein_sysdata.relation re,
	topo_rein.ttt_rows_affected_in_org_table ud, 
	topo_rein_sysdata.edge_data ed,
	topo_rein.reindrift_anlegg_linje  a
	WHERE 
	ud.id = a.id AND
	(a.linje).id = re.topogeo_id AND
	re.layer_id =  border_layer_id AND 
	re.element_type = 2 AND  -- TODO use variable element_type_edge=2
	ed.edge_id = re.element_id AND
	ST_Intersects(ed.geom,input_geo ) AND
	ST_Length(ed.geom) < ST_Length(input_geo) AND
	ST_Length(input_geo)/ST_Length(ed.geom) > 20;
	
	-- Create the new geo with out the short edges
	DROP TABLE IF EXISTS topo_rein.ttt_short_object_list;
	CREATE TABLE topo_rein.ttt_short_object_list(id int, geom geometry);
	INSERT INTO topo_rein.ttt_short_object_list(id,geom)
	SELECT b.id, ST_union(ed.geom) AS geom
	FROM topo_rein.ttt_short_edge_list b,
	topo_rein_sysdata.edge_data ed,
	topo_rein_sysdata.relation re,
	topo_rein.reindrift_anlegg_linje  a
	WHERE a.id = b.id AND
	(a.linje).id = re.topogeo_id AND
	re.layer_id =  border_layer_id AND 
	re.element_type = 2 AND  -- TODO use variable element_type_edge=2
	ed.edge_id = re.element_id AND
	NOT EXISTS (SELECT 1 FROM topo_rein.ttt_short_edge_list WHERE ed.edge_id = edge_id)
	GROUP BY b.id;


	-- Clear the topology elements objects that should be updated
	PERFORM topology.clearTopoGeom(a.linje) 
	FROM topo_rein.reindrift_anlegg_linje  a,
	topo_rein.ttt_short_object_list b
	WHERE a.id = b.id;
	
	-- Remove edges not used from the edge table
 	command_string := FORMAT('
		SELECT ST_RemEdgeModFace(%1$L, ed.edge_id)
		FROM 
		topo_rein.ttt_short_edge_list ued,
		%2$s ed
		WHERE 
		ed.edge_id = ued.edge_id 
		',
		border_topo_info.topology_name,
		border_topo_info.topology_name || '.edge_data'
	);
	
	-- RAISE NOTICE '%', command_string;

    EXECUTE command_string;

	-- clean up edga table
	-- Delete those topology elements objects that does not have edges left
--	DELETE FROM topo_rein_sysdata.edge_data a
--	USING topo_rein.ttt_short_edge_list b
--	WHERE a.edge_id = b.edge_id;

	-- Update the topo objects with shared edges that stil hava 
	UPDATE topo_rein.reindrift_anlegg_linje AS a
	SET linje= topology.toTopoGeom(b.geom, border_topo_info.topology_name, border_layer_id, border_topo_info.snap_tolerance)
	FROM topo_rein.ttt_short_object_list b
	WHERE a.id = b.id;

	
	
																																					
	
	

	--------------------- Stop: Find short eges to be removed  ---------------------

	
	-- TODO should we also return lines that are close to or intersects and split them so it's possible to ??? 
	command_string := ' SELECT distinct tg.id AS id FROM  topo_rein.ttt_rows_affected_in_org_table tg';
	-- command_string := 'SELECT tg.id AS id FROM ' || border_topo_info.layer_schema_name || '.' || border_topo_info.layer_table_name || ' tg, new_rows_added_in_org_table new WHERE new.linje::geometry && tg.linje::geometry';
	RAISE NOTICE '%', command_string;
    RETURN QUERY EXECUTE command_string;
    
END;
$$ LANGUAGE plpgsql;


-- select topo_update.create_line_edge_domain_obj('{"type":"Feature","geometry":{"type":"LineString","crs":{"type":"name","properties":{"name":"EPSG:4258"}},"coordinates":[[23.6848135256,70.2941567505],[23.6861561246,70.2937237249],[23.6888489507,70.2928551851],[23.6896495555,70.2925466063],[23.6917889589,70.292156264],[23.6945956663,70.2918661088],[23.6965659512,70.2915742147],[23.6997477211,70.2913270875],[23.7033391524,70.2915039485],[23.7044653963,70.2916332891],[23.7071834727,70.2915684568],[23.7076455811,70.2914565778],[23.7081927635,70.2912602126],[23.7079468414,70.2907122103]]},"properties":{"reinbeitebruker_id":"YD","reindriftsanleggstype":1}}');

-- select topo_update.create_line_edge_domain_obj('{"type":"Feature","geometry":{"type":"LineString","coordinates":[[582408.943892817,7635222.4433961185],[621500.8918835252,7615523.766478926],[622417.1094145575,7630641.355740958]],"crs":{"type":"name","properties":{"name":"EPSG:32633"}}},"properties":{"Fellesegenskaper.Opphav":"Y","anleggstype":"12","reinbeitebruker_id ":"ZS","Fellesegenskaper.Kvalitet.Maalemetode":82}}');

