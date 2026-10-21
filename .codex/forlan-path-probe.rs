use std::{ffi::c_void, path::PathBuf, os::windows::fs::MetadataExt};
#[path="../src/platform/windows/forlan_reset_files.rs"] mod files;
#[repr(C)] struct Guid { a:u32,b:u16,c:u16,d:[u8;8] }
#[link(name="shell32")] extern "system" {fn SHGetKnownFolderPath(id:*const Guid,flags:u32,token:*mut c_void,path:*mut *mut u16)->i32;}
#[link(name="ole32")] extern "system" {fn CoTaskMemFree(p:*mut c_void);}
#[link(name="kernel32")] extern "system" {fn OpenProcess(access:u32,inherit:i32,pid:u32)->*mut c_void;fn QueryFullProcessImageNameW(process:*mut c_void,flags:u32,buffer:*mut u16,size:*mut u32)->i32;fn CloseHandle(h:*mut c_void)->i32;fn GetPackageFullName(process:*mut c_void,size:*mut u32,name:*mut u16)->i32;fn GetCurrentProcess()->*mut c_void;}
fn main(){
 let id=Guid{a:0xF1B32785,b:0x6FBA,c:0x4FCF,d:[0x9D,0x55,0x7B,0x8E,0x7F,0x15,0x70,0x91]};
 let mut ptr=std::ptr::null_mut(); let hr=unsafe{SHGetKnownFolderPath(&id,0,std::ptr::null_mut(),&mut ptr)};
 if hr<0 {println!("knownfolder HRESULT {hr:x}");return;}
 let mut len=0;while unsafe{*ptr.add(len)}!=0{len+=1;}
 let root=PathBuf::from(String::from_utf16_lossy(unsafe{std::slice::from_raw_parts(ptr,len)}));unsafe{CoTaskMemFree(ptr.cast())};
 println!("known local: {}",root.display()); println!("env local: {:?}",std::env::var("LOCALAPPDATA"));
 println!("file canonical {:?}",std::fs::canonicalize(root.join("forlandestek/ForlanDestek.exe")));
 println!("owned cache paths {:?}",files::owned_tree_paths(&root.join("forlandestek"),&root,"Local"));
 if let Ok(roaming)=std::env::var("APPDATA") {println!("owned profile paths {:?}",files::owned_tree_paths(&PathBuf::from(roaming).join("ForlanDestek"),&root,"Roaming"));}
 for path in root.join("forlandestek").ancestors(){println!("ancestor {} attrs {:?} canonical {:?}",path.display(),std::fs::symlink_metadata(path).map(|m|m.file_attributes()),std::fs::canonicalize(path));}
 for pid in [0,6960] {let handle=if pid==0{unsafe{GetCurrentProcess()}}else{unsafe{OpenProcess(0x1000,0,pid)}};let mut buffer=vec![0u16;32768];let mut size=buffer.len() as u32;let ok=unsafe{QueryFullProcessImageNameW(handle,0,buffer.as_mut_ptr(),&mut size)};println!("pid {} query {} image {}",pid,ok,String::from_utf16_lossy(&buffer[..size as usize]));let mut size=buffer.len() as u32;let rc=unsafe{GetPackageFullName(handle,&mut size,buffer.as_mut_ptr())};println!("pid {} package rc {} name {}",pid,rc,if rc==0{String::from_utf16_lossy(&buffer[..size as usize])}else{String::new()});if pid!=0{unsafe{CloseHandle(handle)};}}
}
