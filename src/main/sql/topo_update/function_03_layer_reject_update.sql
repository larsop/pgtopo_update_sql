

-- set status to 10 for givene object 

-- _data_update_log_id_before int, this id used to get info from the change log
-- _saksbehandler varchar this is the logged in user

drop function if exists topo_update.layer_reject_update(_data_update_log_id_before int, _saksbehandler varchar ) ;


CREATE OR REPLACE FUNCTION topo_update.layer_reject_update(_data_update_log_id_before int, _saksbehandler varchar ) 
RETURNS int AS $$DECLARE

num_rows_affected int;

-- holds dynamic sql to be able to use the same code for different
command_string text;

this_schema_name text;

this_table_name text;

this_data_row_id int;

this_json_row_data text;

an_old_id int;


BEGIN

	-- TODO diable trigger whe update done by this code 
	
	-- get schema name and table nam,e value
	select s.schema_name, s.table_name, s.row_id, s.json_row_data::text 
	into this_schema_name, this_table_name, this_data_row_id, this_json_row_data
	from topo_rein.data_update_log s
	where s.id = _data_update_log_id_before and s.change_confirmed_by_admin = false;

	-- update attributtes to old values
	IF this_json_row_data <> '{}'::text THEN
		perform topo_update.apply_attr_on_topo_layer(
		'{"properties":'||((this_json_row_data::json->'objects'->'collection'->'geometries'->>0)::json->'properties')::text||'}',
		this_schema_name, 
		this_table_name);	
	ELSE 
		command_string := format('update %I.%I set slette_status_kode = 1 where id = %L',
		this_schema_name, this_table_name, this_data_row_id);
		RAISE NOTICE 'command_string %' , command_string;
		EXECUTE command_string;
	END IF;


	update topo_rein.data_update_log s
	set change_confirmed_by_admin = true
	where s.row_id = this_data_row_id and s.schema_name = this_schema_name and s.table_name = this_table_name and s.change_confirmed_by_admin = false;
	GET DIAGNOSTICS num_rows_affected = ROW_COUNT;
	RAISE NOTICE 'Number of meta rows affected  %',  num_rows_affected;
	
	
	


	RETURN num_rows_affected;

END;
$$ LANGUAGE plpgsql;


--select topo_update.layer_reject_update(1,'eee');

--select ('{"type":"Topology", "crs":{"type":"name","properties":{"name":"EPSG:32633"}},"objects":{"collection": { "type": "GeometryCollection", "geometries":[{ "type": "MultiPolygon", "arcs": [[[0]]],"properties":{"id":1,"reindrift_sesongomrade_kode":1,"reinbeitebruker_id":"ZD","fellesegenskaper.forstedatafangstdato":"2015-01-01","fellesegenskaper.verifiseringsdato":"2015-02-02","fellesegenskaper.oppdateringsdato":"2019-01-31","fellesegenskaper.opphav":"Distrikt","alle_reinbeitebr_id":"","status":10,"slette_status_kode":0,"editable":true,"saksbehandler":"Disktrikt_ZD@mail"}}]}},"arcs": [[[-40043,6527640],[-40026,6527873],[-39880,6527855],[-39938,6527591],[-40043,6527640]]]}'::json->'objects'->'collection'->'geometries'->>0)::json->'properties'
-- SELECT topo_update.apply_attr_on_topo_line(
-- '{"properties":{"id":1,"reinbeitebruker_id":"ZH","fellesegenskaper.forstedatafangstdato":"2001-01-22","fellesegenskaper.verifiseringsdato":null,"slette_status_kode":0}}',
-- 'topo_rein', 'arstidsbeite_var_flate', 'omrade',
--'{"properties":{"status":"0","saksbehandler":"imi@nibio.no","reinbeitebruker_id":null,"fellesegenskaper.opphav":"NIBIO"}}');

--	select '{"properties":'||((s.json_row_data::json->'objects'->'collection'->'geometries'->>0)::json->'properties')::text||'}'
--	from topo_rein.data_update_log s
--	where s.id = 1 and s.change_confirmed_by_admin = false;	
