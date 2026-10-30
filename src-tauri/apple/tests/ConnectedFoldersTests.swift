import Foundation

@main enum ConnectedFoldersTests {
    static var checks = 0
    static func assert(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw NSError(domain:"NativeRegression",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }; checks += 1
    }
    static func fails(_ contains:String, _ run:()throws->Any) throws {
        do { _ = try run(); throw NSError(domain:"NativeRegression",code:2,userInfo:[NSLocalizedDescriptionKey:"Expected failure: \(contains)"]) }
        catch { try assert(error.localizedDescription.contains(contains),"Wrong diagnostic: \(error)") }
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass the isolated archive fixture directory") }
        let fm=FileManager.default,base=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString),root=base.appendingPathComponent("workspace"),state=base.appendingPathComponent("state")
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        try Data("original\n".utf8).write(to:root.appendingPathComponent("proof.txt"))
        let engine=try ConnectedFolderEngine(storage:state),folder=try engine.connect(root),id=folder["id"] as! String
        func call(_ args:[String:Any],agent:Bool=false,op:String=UUID().uuidString)throws->[String:Any]{try engine.handle(["action":"execute","folderId":id,"agent":agent,"operationId":op,"args":args]) as! [String:Any]}
        let first=try call(["command":"ReadFile","filePath":"proof.txt"])
        try assert(first["text"] as? String == "original\n","Read original")
        try fails("NOT_AUTHORIZED"){try call(["command":"ReadFile","filePath":"proof.txt"],agent:true)}
        _=try engine.handle(["action":"grant","folderId":id,"access":"read"])
        try assert(try call(["command":"ReadFile","filePath":"proof.txt"],agent:true)["text"] as? String == "original\n","Read grant")
        try fails("NOT_AUTHORIZED"){try call(["command":"WriteFile","filePath":"x.txt","content":"blocked"],agent:true)}
        _=try engine.handle(["action":"grant","folderId":id,"access":"write"])
        let args:[String:Any]=["command":"WriteFile","filePath":"proof.txt","content":"changed\n","overwrite":true,"expectedVersion":first["version"]!]
        let changed=try call(args,agent:true,op:"write-once"),backup=changed["backupId"] as! String
        try assert(try String(contentsOf:root.appendingPathComponent("proof.txt"),encoding:.utf8)=="changed\n","Original modified in place")
        try assert(try String(contentsOf:state.appendingPathComponent("backups/\(backup)/original"),encoding:.utf8)=="original\n","Backup precedes edit")
        _=try call(args,agent:true,op:"write-once")
        try assert((try engine.handle(["action":"backups","folderId":id]) as! [[String:Any]]).count==1,"Retry did not create another backup or write")
        try fails("REQUEST_CONFLICT"){try call(["command":"WriteFile","filePath":"other.txt","content":"different"],agent:true,op:"write-once")}
        try fails("CONFLICT"){try call(["command":"WriteFile","filePath":"proof.txt","content":"stale","overwrite":true,"expectedVersion":first["version"]!])}
        try assert(try String(contentsOf:root.appendingPathComponent("proof.txt"),encoding:.utf8)=="changed\n","Stale edit preserved newest bytes")
        for path in ["../outside.txt","/etc/passwd","a/../../outside","a\\b",".","a//b"] {try fails("INVALID_PATH"){try call(["command":"ReadFile","filePath":path])}}
        try Data("outside".utf8).write(to:base.appendingPathComponent("outside.txt"));try fm.createSymbolicLink(at:root.appendingPathComponent("escape"),withDestinationURL:base)
        try fails("SYMLINK"){try call(["command":"ReadFile","filePath":"escape/outside.txt"])}
        try fails("SYMLINK"){try call(["command":"WriteFile","filePath":"escape/created.txt","content":"no"])}
        _=try engine.handle(["action":"restore","folderId":id,"backupId":backup,"expectedVersion":changed["version"]!])
        try assert(try String(contentsOf:root.appendingPathComponent("proof.txt"),encoding:.utf8)=="original\n","Restore original")
        let current=try call(["command":"FileInfo","filePath":"proof.txt"])
        let moved=try call(["command":"RenameFile","sourcePath":"proof.txt","destinationPath":"renamed.txt","expectedVersion":current["version"]!])
        try assert(!fm.fileExists(atPath:root.appendingPathComponent("proof.txt").path),"Rename source moved")
        try assert(fm.fileExists(atPath:state.appendingPathComponent("backups/\(moved["backupId"]!)/original").path),"Rename backed up")
        let removed=try call(["command":"DeleteFile","filePath":"renamed.txt","expectedVersion":moved["version"]!])
        try assert(!fm.fileExists(atPath:root.appendingPathComponent("renamed.txt").path),"Delete source")
        _=try engine.handle(["action":"restore","folderId":id,"backupId":removed["backupId"]!,"expectedVersion":"missing"])
        try assert(fm.fileExists(atPath:root.appendingPathComponent("renamed.txt").path),"Restore removed file")
        _=try call(["command":"WriteFile","filePath":"new.txt","content":"new file"])
        try fails("EXISTS"){try call(["command":"WriteFile","filePath":"new.txt","content":"would overwrite"])}
        // A failed backup must block modification, not silently continue.
        let snapshots=state.appendingPathComponent("backups");try fm.moveItem(at:snapshots,to:state.appendingPathComponent("retained-backups"));try Data("blocked".utf8).write(to:snapshots)
        let newInfo=try call(["command":"FileInfo","filePath":"new.txt"])
        try fails("BACKUP_FAILED"){try call(["command":"WriteFile","filePath":"new.txt","content":"bad","overwrite":true,"expectedVersion":newInfo["version"]!])}
        try assert(try String(contentsOf:root.appendingPathComponent("new.txt"),encoding:.utf8)=="new file","Backup failure protected source")
        try fm.removeItem(at:snapshots);try fm.moveItem(at:state.appendingPathComponent("retained-backups"),to:snapshots)
        let reopened=try ConnectedFolderEngine(storage:state)
        try assert((try reopened.handle(["action":"folders"]) as! [[String:Any]]).first?["id"] as? String == id,"Bookmark persisted")
        _=try reopened.handle(["action":"disconnect","folderId":id]);try fails("NOT_CONNECTED"){try reopened.handle(["action":"execute","folderId":id,"args":["command":"ListDirectory","directoryPath":""]])}
        let reconnected=try reopened.connect(root);try assert(reconnected["id"] as? String == id,"Reconnect retained backup identity");try assert(reconnected["agentAccess"] as? String == "off","Disconnect revoked tool access")
        try assert((try reopened.handle(["action":"backups","folderId":id]) as! [[String:Any]]).count>=4,"Backups survived disconnect")
        print("PASS: \(checks) native assertions. Fixture: \(base.path)")
    }
}
