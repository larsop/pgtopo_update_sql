

-- update attribute values for given topo object
CREATE OR REPLACE FUNCTION topo_update.apply_attr_on_topo_line(json_feature text) 
RETURNS int AS $$DECLARE

num_rows int;


-- this line layer id will picked up by input parameters
line_layer_id int;


-- TODO use as parameter put for testing we just have here for now
line_topo_info topo_update.input_meta_info ;

-- hold striped gei
edge_with_out_loose_ends geometry = null;

-- holds dynamic sql to be able to use the same code for different
command_string text;

-- holds the num rows affected when needed
num_rows_affected int;

-- used to hold values
felles_egenskaper_flate topo_rein.sosi_felles_egenskaper;
simple_sosi_felles_egenskaper_linje topo_rein.simple_sosi_felles_egenskaper;

BEGIN
	
	-- TODO to be moved is justed for testing now
	line_topo_info.topology_name := 'topo_rein_sysdata';
	line_topo_info.layer_schema_name := 'topo_rein';
	line_topo_info.layer_table_name := 'reindrift_anlegg_linje';
	line_topo_info.layer_feature_column := 'linje';
	line_topo_info.snap_tolerance := 0.0000000001;
	line_topo_info.element_type = 2;
	-- find line layer id
	line_layer_id := topo_update.get_topo_layer_id(line_topo_info);
	
	DROP TABLE IF EXISTS ttt_new_attributes_values;

	CREATE TEMP TABLE ttt_new_attributes_values(geom geometry,properties json);
	
	-- get json data
	INSERT INTO ttt_new_attributes_values(properties)
	SELECT 
--		topo_rein.get_geom_from_json(feat,4258) as geom,
		to_json(feat->'properties')::json  as properties
	FROM (
	  	SELECT json_feature::json AS feat
	) AS f;

	--  
	
	IF (SELECT count(*) FROM ttt_new_attributes_values) != 1 THEN
		RAISE EXCEPTION 'Not valid json_feature %', json_feature;
	ELSE 

		-- TODO find another way to handle this
		SELECT * INTO simple_sosi_felles_egenskaper_linje 
		FROM json_populate_record(NULL::topo_rein.simple_sosi_felles_egenskaper,
		(select properties from ttt_new_attributes_values) );

	END IF;

	
	-- We now know which rows we can reuse clear out old data rom the realation table
	UPDATE topo_rein.reindrift_anlegg_linje r
	SET 
		reindriftsanleggstype = (t2.properties->>'reindriftsanleggstype')::int,
		reinbeitebruker_id = (t2.properties->>'reinbeitebruker_id')::text,
		felles_egenskaper = topo_rein.get_rein_felles_egenskaper_update(felles_egenskaper, simple_sosi_felles_egenskaper_linje)
	FROM ttt_new_attributes_values t2
	-- WHERE ST_Intersects(r.omrade::geometry,t2.geom);
	WHERE id = (t2.properties->>'id')::int;
	
	GET DIAGNOSTICS num_rows_affected = ROW_COUNT;

	RAISE NOTICE 'Number num_rows_affected  %',  num_rows_affected;
	

	
	RETURN num_rows_affected;

END;
$$ LANGUAGE plpgsql;



