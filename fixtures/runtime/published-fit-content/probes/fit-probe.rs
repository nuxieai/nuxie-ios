use nux_capi::*;
use std::ptr;
fn sv(s:&str)->NuxStringView {NuxStringView{data:s.as_ptr().cast(),len:s.len()}}
fn ok(s:NuxStatus){assert_eq!(s,NuxStatus::Ok);}
unsafe fn text(s:NuxStringView)->String {unsafe{String::from_utf8(std::slice::from_raw_parts(s.data.cast(),s.len).to_vec()).unwrap()}}
unsafe fn step(p:*mut NuxPlayer)->(f32,f32){unsafe{let mut r=ptr::null_mut();ok(nux_player_step(p,&NuxPlayerStep::default(),&mut r));nux_player_step_result_free(r);let mut size=NuxPlayerLayoutSize::default();ok(nux_player_layout_size(p,&mut size));(size.width,size.height)}}
fn main(){unsafe{
 let mut info=NuxRuntimeInfo::default();ok(nux_capi_runtime_info(&mut info));let rev=text(info.source_revision);assert_eq!(rev,"bc0a7e7e5d96f328d675ed39142c7549711a8e39");println!("runtime={rev}");
 let path=std::env::args().nth(1).unwrap();let control=path.contains("no-binding");let bytes=std::fs::read(path).unwrap();let mut file=ptr::null_mut();ok(nux_file_import(bytes.as_ptr(),bytes.len(),&NuxRenderCallbacks::default(),&mut file));
 let mut catalog=ptr::null_mut();ok(nux_file_view_model_catalog(file,&mut catalog));let mut ci=NuxViewModelCatalogInfo::default();ok(nux_view_model_catalog_info(catalog,&mut ci));let mut global=None;
 for i in 0..ci.schema_count {let mut schema=NuxViewModelSchemaView::default();ok(nux_view_model_catalog_schema(catalog,i,&mut schema));if text(schema.name)=="$nuxie.presentation" {assert_eq!(schema.is_global,1);assert!(global.is_none());global=Some(schema.schema_index);}}
 let global=global.unwrap();assert!(global>0);ok(nux_view_model_catalog_free(catalog));let mut count=0;ok(nux_file_artboard_count(file,&mut count));
 for name in ["sheet","fill-child","background","sheet"] {
  let index=(0..count).find(|&i|{let mut n=NuxStringView::default();ok(nux_file_artboard_name(file,i,&mut n));text(n)==name}).unwrap();
  let mut players=Vec::new();for _ in 0..2 {let mut a=ptr::null_mut();ok(nux_artboard_instance_new(file,index,&mut a));let mut p=ptr::null_mut();ok(nux_player_new_default(a,&mut p));let mut v=ptr::null_mut();ok(nux_view_model_instance_new(file,global,&mut v));ok(nux_player_set_global_view_model(p,sv("$nuxie.presentation"),v));ok(nux_player_layout_size_set(p,500.0,700.0));players.push((a,p,v));}
  let (_,p,v)=players[0];let other=players[1].1;assert_eq!(step(other),(500.0,700.0));
  for width in [300.0,500.0] {for mode in (if std::env::var_os("FIRST_HUG").is_some(){[2.0,0.0,2.0]}else{[0.0,2.0,0.0]}) {
   ok(nux_player_layout_size_set(p,width,700.0));let mutation=NuxViewModelMutation{kind:NUX_VIEW_MODEL_MUTATION_KIND_SET_NUMBER,instance:v,path:sv("heightMode"),number_value:mode,..Default::default()};let batch=NuxViewModelMutationBatch{mutations:&mutation,mutation_count:1,..Default::default()};let mut result=ptr::null_mut();ok(nux_view_model_mutate(&batch,&mut result));nux_view_model_mutation_result_free(result);let (w,h)=step(p);let untouched=step(other);println!("{name} mode={mode} width={w} height={h} other={}",untouched.1);assert_eq!(untouched,(500.0,700.0));assert_eq!(w,width);if mode==0.0||control {assert_eq!(h,700.0);}else if name=="sheet" {assert_eq!(h,152.0);}
  }}
  for(a,p,v) in players {nux_player_free(p);nux_artboard_instance_free(a);nux_view_model_instance_free(v);}
 }
 nux_file_free(file);
}}
