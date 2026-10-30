use std::io::Write;
use std::path::PathBuf;
use tauri::Manager;
fn directory(app:&tauri::AppHandle)->Result<PathBuf,String>{
    #[cfg(target_os="ios")]
    let base=app.path().document_dir().map_err(|e|e.to_string())?;
    #[cfg(not(target_os="ios"))]
    let base=app.path().app_data_dir().map_err(|e|e.to_string())?;
    Ok(base.join("VCPChat Exports"))
}
fn valid_name(name:&str)->bool{!name.trim().is_empty()&&name!="."&&name!=".."&&name.len()<=240&&!name.chars().any(|c|c=='/'||c=='\\'||c.is_control())}
pub fn export(app:&tauri::AppHandle,name:&str,bytes:&[u8])->Result<String,String>{export_in(directory(app)?,name,bytes)}
fn export_in(root:PathBuf,name:&str,bytes:&[u8])->Result<String,String>{
    if !valid_name(name){return Err("导出文件名无效".into());}if bytes.len()>20_000_000{return Err("导出文件超过20MB".into());}
    std::fs::create_dir_all(&root).map_err(|e|e.to_string())?;
    for index in 0..1000 {let filename=if index==0{name.to_string()}else{format!("{index}-{name}")};let path=root.join(filename);
        match std::fs::OpenOptions::new().write(true).create_new(true).open(&path){
            Ok(mut file)=>{if let Err(error)=file.write_all(bytes).and_then(|_|file.sync_all()){let _=std::fs::remove_file(&path);return Err(error.to_string());}return Ok(path.to_string_lossy().into_owned());},
            Err(error) if error.kind()==std::io::ErrorKind::AlreadyExists=>continue,
            Err(error)=>return Err(error.to_string())
        }
    }Err("同名副本过多，请修改文件名".into())
}
pub fn show(app:&tauri::AppHandle)->Result<String,String>{let root=directory(app)?;std::fs::create_dir_all(&root).map_err(|e|e.to_string())?;
    #[cfg(target_os="macos")]
    {std::process::Command::new("/usr/bin/open").arg(&root).spawn().map_err(|e|e.to_string())?;}
    #[cfg(target_os="ios")]
    {return Ok("文件 App → 我的 iPhone → VCPChat → VCPChat Exports".into());}
    #[cfg(not(target_os="ios"))]
    Ok(root.to_string_lossy().into_owned())
}
#[cfg(test)]mod tests{use super::*;#[test]fn rejects_paths(){for name in ["../a","/a","a/b","a\\b",".","..",""]{assert!(!valid_name(name));}assert!(valid_name("测试报告.pdf"));}
#[test]fn export_never_overwrites(){let root=std::env::temp_dir().join(format!("vcpchat-export-{}",std::process::id()));std::fs::create_dir_all(&root).unwrap();let a=export_in(root.clone(),"proof.txt",b"first").unwrap();let b=export_in(root.clone(),"proof.txt",b"second").unwrap();assert_ne!(a,b);assert_eq!(std::fs::read(a).unwrap(),b"first");std::fs::remove_dir_all(root).unwrap();}}
