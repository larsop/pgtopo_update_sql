-- apply the list of new surfaces to the exting list
-- return the id's of the rows affected

-- DROP FUNCTION topo_update.update_domain_surface_layer(_new_topo_objects regclass) cascade;


CREATE OR REPLACE FUNCTION topo_update.update_domain_surface_layer(_new_topo_objects regclass) 
RETURNS SETOF topo_update.topogeometry_def AS $$
DECLARE

-- this border layer id will picked up by input parameters
border_layer_id int;

-- this surface layer id will picked up by input parameters
surface_layer_id int;

-- this is the tolerance used for snap to 
snap_tolerance float8 = 0.0000000001;

-- TODO use as parameter put for testing we just have here for now
border_topo_info topo_update.input_meta_info ;
surface_topo_info topo_update.input_meta_info ;

-- hold striped gei
edge_with_out_loose_ends geometry = null;

-- holds dynamic sql to be able to use the same code for different
command_string text;

-- holds the num rows affected when needed
num_rows_affected int;

-- number of rows to delete from org table
num_rows_to_delete int;

-- The border topology
new_border_data topogeometry;


BEGIN
	
	-- TODO to be moved is justed for testing now
	border_topo_info.topology_name := 'topo_rein_sysdata';
	border_topo_info.layer_schema_name := 'topo_rein';
	border_topo_info.layer_table_name := 'arstidsbeite_var_grense';
	border_topo_info.layer_feature_column := 'grense';
	border_topo_info.snap_tolerance := 0.0000000001;
	border_topo_info.element_type = 2;
	
	
	surface_topo_info.topology_name := 'topo_rein_sysdata';
	surface_topo_info.layer_schema_name := 'topo_rein';
	surface_topo_info.layer_table_name := 'arstidsbeite_var_flate';
	surface_topo_info.layer_feature_column := 'omrade';
	surface_topo_info.snap_tolerance := 0.0000000001;
	
	-- find border layer id
	border_layer_id := topo_update.get_topo_layer_id(border_topo_info);
	RAISE NOTICE 'border_layer_id   %',  border_layer_id ;
	
	-- find surface layer id
	surface_layer_id := topo_update.get_topo_layer_id(surface_topo_info);
	RAISE NOTICE 'surface_layer_id   %',  surface_layer_id ;

	-- get the data into a new tmp table
	DROP TABLE IF EXISTS new_surface_data; 

	
	EXECUTE format('CREATE TEMP TABLE new_surface_data AS (SELECT * FROM %s)', _new_topo_objects);
	
	DROP TABLE IF EXISTS old_surface_data; 
	-- find out if any old topo objects overlaps with this new objects using the relation table
	-- by using the surface objects owned by the both the new objects and the exting one
	CREATE TEMP TABLE old_surface_data AS 
	(SELECT 
	re.* 
	FROM 
	topo_rein_sysdata.relation re,
	topo_rein_sysdata.relation re_tmp,
	new_surface_data new_sd
	WHERE 
	re.layer_id = surface_layer_id AND
	re.element_type = 3 AND
	re.element_id = re_tmp.element_id AND
	re_tmp.layer_id = surface_layer_id AND
	re_tmp.element_type = 3 AND
	(new_sd.surface_topo).id = re_tmp.topogeo_id AND
	(new_sd.surface_topo).id != re.topogeo_id);
	
	
	DROP TABLE IF EXISTS old_surface_data_not_in_new; 
	-- find any old objects that are not covered totaly by 
	-- this objets should not be deleted, but the geometry should only decrease in size.
	-- TODO add a test case for this
	CREATE TEMP TABLE old_surface_data_not_in_new AS 
	(SELECT 
	re.* 
	FROM 
	topo_rein_sysdata.relation re,
	old_surface_data re_tmp
	WHERE 
	re.layer_id = surface_layer_id AND
	re.element_type = 3 AND
	re.topogeo_id = re_tmp.topogeo_id AND
	re.element_id NOT IN (SELECT element_id FROM old_surface_data));
	
	
	DROP TABLE IF EXISTS old_rows_be_reused;
	-- IF old_surface_data_not_in_new is empty we know that all areas are coverbed by the new objects
	-- and we can delete/resuse this objects for the new rows
	CREATE TEMP TABLE old_rows_be_reused AS 
	-- we can have distinct here 
	(SELECT distinct(old_data_row.id) FROM 
	topo_rein.arstidsbeite_var_flate old_data_row,
	old_surface_data sf 
	WHERE (old_data_row.omrade).id = sf.topogeo_id);  
	
	-- We now know which rows we can reuse clear out old data rom the realation table
	UPDATE topo_rein.arstidsbeite_var_flate r
	SET omrade = clearTopoGeom(omrade)
	FROM old_rows_be_reused reuse
	WHERE reuse.id = r.id;
	
	GET DIAGNOSTICS num_rows_affected = ROW_COUNT;

	RAISE NOTICE 'Number num_rows_affected  %',  num_rows_affected;

	SELECT (num_rows_affected - (SELECT count(*) FROM new_surface_data)) INTO num_rows_to_delete;

	RAISE NOTICE 'Number of new rows  %',  count(*) FROM new_surface_data;

	RAISE NOTICE 'Nnum rows to delete  %',  num_rows_to_delete;

	-- When overwrite we may have more rows in the org table so we may need do delete the rows not needed 
	-- from  topo_rein.arstidsbeite_var_flate, we the just delete the left overs 
	DELETE FROM topo_rein.arstidsbeite_var_flate
	WHERE ctid IN (
	SELECT r.ctid FROM
	topo_rein.arstidsbeite_var_flate r,
	old_rows_be_reused reuse
	WHERE reuse.id = r.id 
	LIMIT  greatest(num_rows_to_delete, 0));
	
	
	-- Resus old rows in topo_rein.arstidsbeite_var_flate and use as many values as possible
	-- We pick the new values from new_surface_data
	-- First we pick up values with the same topo object value id
	UPDATE topo_rein.arstidsbeite_var_flate old
	SET omrade = new.surface_topo
	FROM new_surface_data new,
	old_rows_be_reused reuse
	WHERE old.id = reuse.id ;
	
	
	-- insert missing rows
	INSERT INTO  topo_rein.arstidsbeite_var_flate(omrade)
	SELECT new.surface_topo 
	FROM new_surface_data new
	WHERE NOT EXISTS ( SELECT f.id FROM topo_rein.arstidsbeite_var_flate f WHERE (new.surface_topo).id = (f.omrade).id );

		
	
	--RETURN QUERY SELECT a.surface_topo::topogeometry as t FROM new_surface_data a;
	
	RETURN QUERY SELECT a.surface_topo::topogeometry as t FROM new_surface_data a;

	
END;
$$ LANGUAGE plpgsql;


