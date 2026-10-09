use crate::Pipeline;
use experience_files::{RepoFiles, RepoPath};
#[test]
fn nested_sdk_fixture() {
 let state=r#"{"$schema":"https://nuxie.com/schema/experience/1.json","entry":{"steps":[]},"state":{"profile":{"type":"object","fields":{"name":{"type":"string","default":"Ana"},"minutes":{"type":"number","default":10},"empty":{"type":"number"},"settings":{"type":"object","fields":{"minutes":{"type":"number","default":12},"day":{"type":"date","default":"2026-10-09"}}},"topics":{"type":"enum","values":["Reading, writing","Travel"],"multiple":true,"default":["Travel"]}}},"top":{"type":"number","default":7}}}"#;
 let files=RepoFiles::from_files([
 ("experience.json",state),
 ("screens/first/frame.json",r#"{"$schema":"https://nuxie.com/schema/frame/1.json","size":{"width":390,"height":844}}"#),
 ("screens/first/index.html",r#"<html><body><div style="width: 100px; height: 100px; background: #ff0000"></div></body></html>"#),
 ].map(|(p,t)|(RepoPath::parse(p).unwrap(),t.to_owned()))).unwrap();
 let mut p=Pipeline::mounted(files,"nested-sdk",0).unwrap();
 assert!(p.problems().is_empty(),"{:?}",p.problems());
 let built=p.live.published_document().unwrap();
 let h=rive_compiler_core::RuntimeHeaderInput{major_version:7,minor_version:0,file_id:1,property_field_types:rive_compiler_core::derive_header_property_field_types(built.records())};
 let bytes=rive_compiler_core::encode_riv_file(&h,built.records()).unwrap();
 std::fs::write(std::env::var("NESTED_SDK_FIXTURE_OUT").unwrap(),bytes).unwrap();
 println!("published nested SDK fixture");
}
