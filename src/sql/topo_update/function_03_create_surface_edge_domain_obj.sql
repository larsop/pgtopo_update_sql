-- Internal service function
CREATE OR REPLACE FUNCTION topo_update.check_split_border(
  line GEOMETRY,
  toponame TEXT
) RETURNS GEOMETRY AS $BODY$ --{
DECLARE
  line_intersection_result GEOMETRY;
  sql TEXT;
  num_edge_intersects INT;
BEGIN
	-- modify the input geometry if it's not simple.
	IF NOT ST_IsSimple(line) THEN
		-- This is probably a crossing line so we try to build a surface
		BEGIN
			line_intersection_result := ST_BuildArea(ST_UnaryUnion(line))::geometry;
			RAISE DEBUG 'topo_update.check_split_border Line intersection result is %', ST_AsText(line_intersection_result);
			line := ST_ExteriorRing(line_intersection_result);
		EXCEPTION WHEN others THEN
			RAISE DEBUG 'topo_update.check_split_border Error code: %', SQLSTATE;
			RAISE DEBUG 'topo_update.check_split_border Error message: %', SQLERRM;
			RAISE DEBUG 'topo_update.check_split_border Failed to to use line intersection result is %, try buffer', ST_AsText(line_intersection_result);
			line := ST_ExteriorRing(ST_Buffer(line_intersection_result,0.00000000001));
		END;

		-- check the object after a fix
		RAISE DEBUG 'topo_update.check_split_border Fixed a non simple line to be valid simple line by using by buildArea %',  line;
	ELSIF NOT ST_IsClosed(line) THEN
		-- If this is not closed just check that it intersects two times with a exting border
		-- TODO make more precice check that only used edges that in varbeite surface
		-- TODO handle return of gemoerty collection
		-- thic code fails need to make a test on this

		sql := format($$
SELECT ST_Union(ST_Intersection($1, e.geom))
FROM %I.edge_data e
WHERE ST_Intersects($1, e.geom)
		$$, toponame);
		RAISE DEBUG 'topo_update.check_split_border sql %', sql;

		EXECUTE sql USING line
		INTO line_intersection_result;

		RAISE DEBUG 'topo_update.check_split_border Line intersection result is %', ST_AsText(line_intersection_result);

		num_edge_intersects := COALESCE(ST_NumGeometries(line_intersection_result), 0);

		RAISE DEBUG 'topo_update.check_split_border: non closed linestring intersects % times with topology edges', num_edge_intersects;
		IF num_edge_intersects = 0 THEN
			RAISE EXCEPTION 'Non closed linestring does not intersect any edges';
		ELSIF num_edge_intersects = 1 THEN
			line := ST_ExteriorRing(ST_BuildArea(ST_UnaryUnion(ST_AddPoint(line, ST_StartPoint(line)))));
		ELSIF num_edge_intersects > 2 THEN
			RAISE EXCEPTION 'Found a non valid linestring does intersect % times, with any borders by using buildArea %', num_edge_intersects, line;
		END IF;
	END IF;
  RETURN line;
END; --}

$BODY$ LANGUAGE 'plpgsql';


--
-- This function will be called from the client when the user
-- draws a line to either create a new surface or extend an
-- existing one.
--
-- If the border line will not form a new surface or modify
-- an existing one, nothing is be done, otherwise:
--
--   1. The line, with associated attributes,
--      is added into the border layer.
--
--   2. New surfaces created by addition of the border
--      are found and added into the surface layer.
--      Attributes for the new surface records will be
--      inherited by the surface originally covering the
--      space now covered by the new surface.
--
-- The returned value is an array of objects (in JSON format)
-- having keys:
--		- id integer, a TopoGeometry identifier
--      - id_type char, S or L, saying if the TopoGeometry
--                      was created in the surface layer (S)
--                      or the border layer (L)
--
-- NOTE: the return is typed as TEXT because Java clients
--       may have trouble with JSON type return from functions
--
-- TODO set attributes for the line
-- TODO set attributes for the surface
--
-- {
CREATE OR REPLACE FUNCTION topo_update.create_surface_edge_domain_obj(

	-- A GeoJSON Feature object
	-- See https://geojson.org/
	client_json_feature text,

	-- Name of the schema containing both
	-- Surface and Border layer
	layer_schema text,

	-- Name of Surface layer table
	surface_layer_table text,

	-- Name of Surface layer TopoGeometry column
	surface_layer_column text,

	-- Name of Border layer table
	border_layer_table text,

	-- Name of Border layer TopoGeometry column
	border_layer_column text,

	snap_tolerance float8,

	server_json_feature text default null
)
RETURNS TABLE(result text) AS $BODY$
DECLARE

	json_result text;

	new_border topology.topogeometry;

	-- TODO use as parameter put for testing we just have here for now
	border_topo_info topo_update.input_meta_info ;
	surface_topo_info topo_update.input_meta_info ;

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

	-- the orignal geo that is from the user
	org_geo_in geometry;

	line_intersection_result geometry;

	-- array of quoted field identifiers
	-- for attribute fields passed in by user and known (by name)
	-- in the target table
	not_null_fields text[];

	-- holde the computed value for json input reday to use
	json_input_structure topo_update.json_input_structure;

	-- do debug timing
	do_timing_debug boolean = true;
	ts timestamptz := clock_timestamp();
	proc_name text = 'topo_update.create_surface_edge_domain_obj';

BEGIN

	IF do_timing_debug THEN
		RAISE NOTICE '% time spent % start at %', proc_name, clock_timestamp() - ts, clock_timestamp();
	END IF;

	-- get topology meta data like layer num, srid, ... for the border line layer for this surface
	border_topo_info := topo_update.make_input_meta_info(layer_schema, border_layer_table , border_layer_column );

	-- get topology meta data like layer num, srid, ... for the surface layer
	surface_topo_info := topo_update.make_input_meta_info(layer_schema, surface_layer_table , surface_layer_column );

	-- parse the input values and find input geo and properties.
	-- If there are properties with equal name found both in
	-- client_json_feature and server_json_feature, then the values
	-- in server_json_feature will be used.
	json_input_structure := topo_update.handle_input_json_props(
		client_json_feature::json,
		server_json_feature::json,
		4258
	);

	-- save a copy of the input geometry before modfied, used for logging later.
	org_geo_in := json_input_structure.input_geo;

	IF do_timing_debug THEN
		RAISE NOTICE '% client_json_feature %', proc_name, client_json_feature;
		RAISE NOTICE '% server_json_feature %', proc_name, server_json_feature;
		RAISE NOTICE '% The input as it used before check/fixed %',  proc_name, ST_AsText(json_input_structure.input_geo);
		RAISE NOTICE '% json_input_structure %', proc_name, json_input_structure;
		RAISE NOTICE '% time spent % to get to init stage', proc_name, clock_timestamp() - ts;
	END IF;

	-- Only used for debug
	IF add_debug_tables = 1 THEN
		-- get new objects created from topo_update.create_edge_surfaces
		DROP TABLE IF EXISTS topo_rein.create_surface_edge_domain_obj_t0;
		CREATE TABLE topo_rein.create_surface_edge_domain_obj_t0(geo_in geometry, IsSimple boolean, IsClosed boolean);
		INSERT INTO topo_rein.create_surface_edge_domain_obj_t0(geo_in,IsSimple,IsClosed) VALUES(json_input_structure.input_geo,St_IsSimple(json_input_structure.input_geo),St_IsSimple(json_input_structure.input_geo));
	END IF;

	json_input_structure.input_geo := topo_update.check_split_border(json_input_structure.input_geo, border_topo_info.topology_name);

	IF do_timing_debug THEN
		RAISE NOTICE '% time spent % to reach state where input check is done', proc_name, clock_timestamp() - ts;
	END IF;

	-- check the geometry is not null after it potencially may have checked/changed.
	IF json_input_structure.input_geo IS NULL THEN
		RAISE EXCEPTION 'The geo generated from json_input_structure.input_geo is null %', org_geo_in;
	END IF;

	IF add_debug_tables = 1 THEN
		INSERT INTO topo_rein.create_surface_edge_domain_obj_t0(json_input_structure.input_geo,IsSimple,IsClosed)
		VALUES(json_input_structure.input_geo,St_IsSimple(json_input_structure.input_geo),St_IsClosed(json_input_structure.input_geo));
	END IF;


	-- Create the new topo object for the egde layer, this edges will be used by the new surface objects later
	new_border := topo_update.create_surface_edge(json_input_structure.input_geo,border_topo_info);
	IF do_timing_debug THEN
		RAISE NOTICE 'topo_update.create_surface_edge_domain_obj The input as it used after check/fixed %',  ST_AsText(json_input_structure.input_geo);
		RAISE NOTICE 'topo_update.create_surface_edge_domain_obj The new topo object created for based on the input geo % in table %.%',  new_border, border_topo_info.layer_schema_name,border_topo_info.layer_table_name;
		RAISE NOTICE '% time spent % to reach state where new_border is by calling ', proc_name, clock_timestamp() - ts;
	END IF;


	-- Create temporary table to hold the new data for the border objects. We here use the same table structure as the restult table.
	command_string := topo_update.create_temp_tbl_as(
	  'ttt2_new_topo_rows_in_org_border_table',
	  format('SELECT * FROM %I.%I LIMIT 0',
	         border_topo_info.layer_schema_name,
	         border_topo_info.layer_table_name));
	EXECUTE command_string;

  	-- Insert a single row into border temp table using the columns from json input that match column names in the temp table craeted
	INSERT INTO ttt2_new_topo_rows_in_org_border_table
	SELECT * FROM json_populate_record(null::ttt2_new_topo_rows_in_org_border_table,json_input_structure.json_properties);

	-- TODO add a test to be sure that only a single row is inserted,

	RAISE NOTICE 'topo_update.create_surface_edge_domain_obj added json_input_structure.json_properties % to ttt2_new_topo_rows_in_org_border_table', json_input_structure.json_properties;

	-- Update the single rows in border line temp table with TopoGeometry and felles egenskaper
	command_string := format('UPDATE ttt2_new_topo_rows_in_org_border_table
    SET %I = %L,
	 felles_egenskaper = %L',
	border_topo_info.layer_feature_column, new_border,json_input_structure.sosi_felles_egenskaper);
  	EXECUTE command_string;

  	IF do_timing_debug THEN
		RAISE NOTICE '% time spent % to reach state Set felles_egenskaper field ', proc_name, clock_timestamp() - ts;
	END IF;


	-- Find name of columns with not-null values from the temp table
	-- We need this list of column names to crete a SQL to update the orignal row with new values.
	SELECT array_agg(quote_ident(key))
	  FROM ttt2_new_topo_rows_in_org_border_table t, json_each_text(to_json((t)))
	WHERE value IS NOT NULL
	  INTO not_null_fields;

	-- Copy data from from temp table in to actual table and
	-- update temp table with actual data stored in actual table.
	-- We will then get values for id's and default values back in to the temp table.
	command_string := format(
	    'WITH inserted AS ( INSERT INTO %I.%I (%s) SELECT %s FROM
		ttt2_new_topo_rows_in_org_border_table RETURNING * ), deleted AS ( DELETE
		FROM ttt2_new_topo_rows_in_org_border_table ) INSERT INTO
		ttt2_new_topo_rows_in_org_border_table SELECT * FROM inserted ',
	    border_topo_info.layer_schema_name,
	    border_topo_info.layer_table_name,
	    array_to_string(not_null_fields, ','),
	    array_to_string(not_null_fields, ',')
	);
	EXECUTE command_string;

	IF do_timing_debug THEN
		RAISE NOTICE '% time spent % to reach state, surface_edge_domain_obj Step::::::::::::::::: 3 ', proc_name, clock_timestamp() - ts;
	END IF;

	-- Create table for the rows to be returned to the caller.
	-- The result contains list of line and surface id so the client knows alle row created.
	CREATE TEMP TABLE create_surface_edge_domain_obj_r1_r(id int, id_type text)
	ON COMMIT DROP;

	RAISE NOTICE 'topo_update.create_surface_edge_domain_obj Step::::::::::::::::: 2';

	-- Insert new line objects created
	INSERT INTO create_surface_edge_domain_obj_r1_r(id,id_type)
	SELECT id, 'L' as id_type FROM ttt2_new_topo_rows_in_org_border_table;

	-- ##############################################################
	-- We are now done with border line objects and we can start to work on the surface objects
	-- The new faces are already created so we new find them and relate our domain objects
	-- ##############################################################

	-- Add new columns for default values

	-- Create a new temp table to hold topo surface objects that
	-- has a relation to the edge added by the user .
	--
	-- find out if any old topo objects overlaps with this new objects using the relation table
	-- by using the surface objects owned by the both the new objects and the exting one
	CREATE TEMP TABLE new_surface_data_for_edge
	ON COMMIT DROP AS
	SELECT
		surface_topo,
		json_input_structure.sosi_felles_egenskaper_flate AS felles_egenskaper,
		NULLIF (json_input_structure.json_properties->>'reinbeitebruker_id'::text,'') as reinbeitebruker_id
	FROM topo_update.create_edge_surfaces(
		surface_topo_info,
		border_topo_info,
		new_border,
		json_input_structure.input_geo,
		json_input_structure.sosi_felles_egenskaper_flate
	) surface_topo;
	-- We now have a list with all surfaces that intersect the line that is drwan by the user.
	-- In this list there may areas that overlaps so we need to clean up some values

	GET DIAGNOSTICS num_rows_affected = ROW_COUNT;

	IF do_timing_debug THEN
		RAISE NOTICE '% time spent % to reach state, Number of topo surfaces added to table new_surface_data_for_edge %', proc_name, clock_timestamp() - ts, num_rows_affected;
	END IF;

	-- Clean up old surface and return a list of the objects that
	-- should be returned to the user for further processing
	CREATE TEMP TABLE res_from_update_domain_surface_layer
	ON COMMIT DROP AS
	SELECT surface_topo
	FROM topo_update.update_domain_surface_layer(
		surface_topo_info,
		border_topo_info,
		json_input_structure,
		'new_surface_data_for_edge'
	) surface_topo;
	GET DIAGNOSTICS num_rows_affected = ROW_COUNT;

	IF do_timing_debug THEN
		RAISE NOTICE '% time spent % to reach state, Number_of_rows removed from topo_update.update_domain_surface_layer %', proc_name, clock_timestamp() - ts, num_rows_affected;
	END IF;

	-- Only used for debug
	IF add_debug_tables = 1 THEN
		-- get new objects created from topo_update.create_edge_surfaces
		DROP TABLE IF EXISTS topo_rein.create_surface_edge_domain_obj_t1;
		CREATE TABLE topo_rein.create_surface_edge_domain_obj_t1 AS
		(SELECT surface_topo::geometry AS geo , surface_topo::text AS topo FROM new_surface_data_for_edge);

		-- get the reslt from topo_update.update_domain_surface_layer
		DROP TABLE IF EXISTS topo_rein.create_surface_edge_domain_obj_t2;
		CREATE TABLE topo_rein.create_surface_edge_domain_obj_t2 AS
		(SELECT surface_topo::geometry AS geo , surface_topo::text AS topo FROM res_from_update_domain_surface_layer);

		-- get new objects created from topo_update.create_edge_surfaces
		DROP TABLE IF EXISTS topo_rein.create_surface_edge_domain_obj_t1_p;
		CREATE TABLE topo_rein.create_surface_edge_domain_obj_t1_p AS
		(SELECT ST_PointOnSurface(surface_topo::geometry) AS geo , surface_topo::text AS topo FROM new_surface_data_for_edge);

	END IF;

	IF ST_IsClosed(json_input_structure.input_geo) THEN
		command_string := format('INSERT INTO create_surface_edge_domain_obj_r1_r(id,id_type) ' ||
		'SELECT tg.id AS id, ''S''::text AS id_type FROM ' ||
		surface_topo_info.layer_schema_name || '.' || surface_topo_info.layer_table_name ||
		' tg, new_surface_data_for_edge new ' ||
		'WHERE (new.surface_topo).id = (tg.%2$s).id AND ' ||
		'ST_intersects(ST_PointOnSurface((new.surface_topo)::geometry), ST_MakePolygon(%1$L))'
		,json_input_structure.input_geo,
		surface_topo_info.layer_feature_column);
    	RAISE NOTICE 'topo_update.create_surface_edge_domain_obj A closed objects only return objects in %', command_string;
  	ELSE
		command_string := 'INSERT INTO create_surface_edge_domain_obj_r1_r(id,id_type) ' ||
		' SELECT tg.id AS id, ''S'' AS id_type FROM ' ||
		surface_topo_info.layer_schema_name || '.' || surface_topo_info.layer_table_name || ' tg, new_surface_data_for_edge new ' ||
		'WHERE (new.surface_topo).id = (tg.'||surface_topo_info.layer_feature_column||').id ';
	END IF;

	EXECUTE command_string;


	IF do_timing_debug THEN
		RAISE NOTICE '% time spent % done at %', proc_name, clock_timestamp() - ts, clock_timestamp();
	END IF;

    RETURN QUERY
	SELECT json_agg(row_to_json(t.*))::text as result
	FROM create_surface_edge_domain_obj_r1_r t;

END;
$BODY$ LANGUAGE plpgsql; --}
