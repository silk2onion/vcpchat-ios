use std::{env, path::PathBuf, process::Command};
fn output(command: &mut Command) -> String {
    let result = command.output().expect("无法启动 Apple 原生编译器");
    assert!(
        result.status.success(),
        "Apple 原生编译失败：\n{}",
        String::from_utf8_lossy(&result.stderr)
    );
    String::from_utf8(result.stdout)
        .expect("编译器路径编码无效")
        .trim()
        .to_owned()
}
fn main() {
    println!("cargo:rerun-if-changed=apple/ConnectedFolders.swift");
    let target = env::var("TARGET").unwrap();
    if target.contains("apple-darwin") || target.contains("apple-ios") {
        let ios = target.contains("apple-ios");
        let sim = target.ends_with("-sim") || target.starts_with("x86_64-apple-ios");
        let sdk = if !ios {
            "macosx"
        } else if sim {
            "iphonesimulator"
        } else {
            "iphoneos"
        };
        let arch = if target.starts_with("aarch64") {
            "arm64"
        } else {
            "x86_64"
        };
        let swift_target = if !ios {
            format!("{arch}-apple-macosx12.0")
        } else if sim {
            format!("{arch}-apple-ios16.0-simulator")
        } else {
            format!("{arch}-apple-ios16.0")
        };
        let sdk_path = output(Command::new("xcrun").args(["--sdk", sdk, "--show-sdk-path"]));
        let swift = PathBuf::from(output(
            Command::new("xcrun").args(["--sdk", sdk, "--find", "swiftc"]),
        ));
        let dir = PathBuf::from(env::var("OUT_DIR").unwrap());
        let object = dir.join("ConnectedFolders.o");
        output(
            Command::new(&swift)
                .args([
                    "-swift-version",
                    "5",
                    "-parse-as-library",
                    "-emit-object",
                    "-module-name",
                    "VCPFolders",
                    "-target",
                    &swift_target,
                    "-sdk",
                    &sdk_path,
                    "-module-cache-path",
                ])
                .arg(dir.join("swift-cache"))
                .arg("apple/ConnectedFolders.swift")
                .arg("-o")
                .arg(&object),
        );
        output(
            Command::new("xcrun")
                .arg("ar")
                .arg("crs")
                .arg(dir.join("libVCPFolders.a"))
                .arg(&object),
        );
        println!("cargo:rustc-link-search=native={}", dir.display());
        println!("cargo:rustc-link-search=native=/usr/lib/swift");
        if let Some(usr) = swift.parent().and_then(|p| p.parent()) {
            println!(
                "cargo:rustc-link-search=native={}",
                usr.join("lib/swift").join(sdk).display()
            );
        }
        println!("cargo:rustc-link-lib=static=VCPFolders");
        for framework in if ios {
            vec!["Foundation", "CryptoKit", "UIKit", "UniformTypeIdentifiers"]
        } else {
            vec!["Foundation", "CryptoKit", "AppKit"]
        } {
            println!("cargo:rustc-link-lib=framework={framework}");
        }
        println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    }
    tauri_build::build()
}
