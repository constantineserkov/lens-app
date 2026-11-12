import Foundation

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw LensError.message(message) }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("Lens-history-check-\(UUID())")
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:root) }
let a = Answer(status:"ok",task:"Question 7.  Find the profit-maximizing\nquantity.",answer:"25.00",format_note:"Two decimal places",solution:"MR = MC\nQ = 25",warnings:[])
let b = Answer(status:"ok",task:"Question 8. Choose the index.",answer:"C",format_note:"0.25",solution:"20 / 80 = 0.25",warnings:[])
let store = HistoryStore(directory:root.appendingPathComponent("normal"))
try check(try store.load().isEmpty,"New archive should be empty")
try check(!FileManager.default.fileExists(atPath:store.file.path),"Reading should not create archive")
let first = try store.append(a)
try check(first.number == 1 && first.answer.answer == "25.00","First entry must retain exact formatted answer")
try check(first.title.contains("Question 7.") && !first.title.contains("\n"),"Title should preserve question number and normalize whitespace")
try check(first.model == "gpt-6.1-sol" && first.reasoning == "high","Model configuration must be pinned")
let reloaded = HistoryStore(directory:store.directory)
let entries = try reloaded.load()
try check(entries.count == 1 && entries[0].id == first.id && entries[0].answer.solution == a.solution,"History must survive restart")
let second = try reloaded.append(b)
try check(second.number == 2,"Numbering must continue after restart")
try check(try HistoryStore(directory:store.directory).load().count == 2,"Previous answers must survive new writes")
let corrupt = HistoryStore(directory:root.appendingPathComponent("corrupt"))
try FileManager.default.createDirectory(at:corrupt.directory,withIntermediateDirectories:true)
let corruptBytes = Data("broken history".utf8)
try corruptBytes.write(to:corrupt.file)
var rejected = false
 do { _ = try corrupt.append(a) } catch { rejected = true }
try check(rejected,"Unreadable history must be rejected")
try check(try Data(contentsOf:corrupt.file) == corruptBytes,"Unreadable history must not be overwritten")
let blocker = root.appendingPathComponent("blocked")
try Data("file".utf8).write(to:blocker)
let failing = HistoryStore(directory:blocker)
rejected = false
 do { _ = try failing.append(a) } catch { rejected = true }
try check(rejected && failing.entries.isEmpty,"Failed save must not change in-memory history")
let permissions = try FileManager.default.attributesOfItem(atPath:store.file.path)[.posixPermissions] as? NSNumber
try check(permissions?.intValue == 0o600,"History should be readable only by its owner")
print("PASS: exact answers, question titles, pinned model, persistence, numbering, corruption protection, failed writes, file permissions")
let visible = CGRect(x:0,y:0,width:1728,height:1080)
let dockAnchor = CGPoint(x:1718,y:12)
let compact = PanelPlacement.frame(size:CGSize(width:88,height:44),anchor:dockAnchor,visible:visible)
let expanded = PanelPlacement.frame(size:CGSize(width:422,height:267),anchor:dockAnchor,visible:visible)
for step in 0...20 {
    let frame = PanelPlacement.interpolate(compact,expanded,progress:CGFloat(step)/20)
    try check(abs(frame.maxX-dockAnchor.x) < 0.001 && abs(frame.minY-dockAnchor.y) < 0.001,"Camera and arrow anchor should stay fixed during expansion")
}
for point in [CGPoint(x:10,y:1050),CGPoint(x:99999,y:-99999)] {
    let frame = PanelPlacement.frame(size:CGSize(width:422,height:267),anchor:point,visible:visible)
    try check(visible.insetBy(dx:8,dy:8).contains(frame),"Panel must remain on screen near edges or after monitor removal")
}
let secondary = CGRect(x:-1728,y:0,width:1728,height:1080)
try check(secondary.insetBy(dx:8,dy:8).contains(PanelPlacement.frame(size:CGSize(width:422,height:267),anchor:CGPoint(x:-10,y:12),visible:secondary)),"Negative monitor coordinates should work")
let middle = PanelPlacement.interpolate(compact,expanded,progress:0.55)
try check(PanelPlacement.interpolate(middle,compact,progress:0) == middle,"Reversing animation must start at its current frame")
print("PASS: fixed control anchor, screen edge clamping, disconnected display recovery, negative display coordinates, continuous reverse animation")

// Exercise process failures and reachability without changing the Mac's network or calling a model.
let image = root.appendingPathComponent("input.png")
try makeFixture(at:image,choice:true)
func fakeCLI(_ name:String,_ body:String)throws->URL {
    let path = root.appendingPathComponent(name)
    let script = """
    #!/bin/sh
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "-o" ]; then shift; output="$1"; fi
      shift
    done
    \(body)
    cat > "$output" <<'JSON'
    {"status":"ok","task":"Test","answer":"1, 3, 5","format_note":"","solution":"Verified","warnings":[]}
    JSON
    printf '%s\\n' '{"type":"turn.completed"}'
    """
    try script.write(to:path,atomically:true,encoding:.utf8)
    try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:path.path)
    return path
}
let recovering = try fakeCLI("recovering", """
printf '%s\\n' '{"type":"turn.started"}'
if [ ! -f attempted ]; then
  touch attempted
  sleep 0.15
  printf '%s\\n' 'stream disconnected; retrying' >&2
  exit 1
fi
""")
var statuses:[SolverProgress] = []
let recovered = try Solver(executable:recovering,connection:{ true },retryDelay:0.05).solve(image:image,instructions:"") { statuses.append($0) }
try check(recovered.answer == "1, 3, 5" && statuses.contains(.retrying(2)),"Transient failures must retry using retained image")
try check(statuses.contains(.processing) && statuses.contains(.connectionIssue) && statuses.contains(.reading),"JSONL and retry status must be observable")
let disconnecting = try fakeCLI("disconnecting", """
if [ ! -f attempted ]; then
  touch attempted
  printf '%s\\n' '{"type":"turn.started"}'
  sleep 5
fi
""")
let began = Date()
statuses = []
let online:()->Bool = { let t = Date().timeIntervalSince(began); return t < 0.5 || t >= 0.9 }
let afterOutage = try Solver(executable:disconnecting,connection:online,retryDelay:0.05).solve(image:image,instructions:"") { statuses.append($0) }
try check(afterOutage.answer == "1, 3, 5" && statuses.contains(.offline),"A dropped connection must recover automatically with the same image")
let cancelled = Solver(executable:recovering,connection:{ false })
DispatchQueue.global().asyncAfter(deadline:.now()+0.15) { cancelled.cancel() }
let cancelStart = Date()
var wasCancelled = false
 do { _ = try cancelled.solve(image:image,instructions:"") }
 catch { wasCancelled = error.localizedDescription.contains("canceled") }
try check(wasCancelled && Date().timeIntervalSince(cancelStart) < 1,"Cancellation must interrupt offline waiting promptly")
let authFailure = try fakeCLI("auth", "printf '%s\\n' '401 unauthorized' >&2; exit 1")
statuses = []; var authRejected = false
 do { _ = try Solver(executable:authFailure,connection:{ true }).solve(image:image,instructions:"") { statuses.append($0) } }
 catch { authRejected = error.localizedDescription.contains("Sign in") }
try check(authRejected && !statuses.contains(.retrying(2)),"Authentication failures must not loop")
let unavailable = try fakeCLI("unavailable", "printf '%s\\n' '503 connection failed' >&2; exit 1")
statuses = []; var bounded = false
 do { _ = try Solver(executable:unavailable,connection:{ true },retryDelay:0.01).solve(image:image,instructions:"") { statuses.append($0) } }
 catch { bounded = error.localizedDescription.contains("4 attempts") }
try check(bounded && statuses.filter { $0 == .retrying(4) }.count >= 1 && !statuses.contains(.retrying(5)),"Online retries must stop after four attempts")
print("PASS: live process stages, transient retry, disconnect/reconnect, offline cancellation, authentication errors, bounded retries")
let serverWait = try fakeCLI("server-wait", """
printf '%s\\n' 'stream disconnected - retrying sampling request (1/5 in 0.7s) last status: 429 Too Many Requests' >&2
sleep 0.8
""")
statuses = []
let afterBackoff = try Solver(executable:serverWait,connection:{ true },retryDelay:0.01,attemptTimeout:0.5).solve(image:image,instructions:"") { statuses.append($0) }
try check(afterBackoff.answer == "1, 3, 5" && statuses.contains(.rateLimited) && !statuses.contains(.retrying(2)),"Server-directed wait must remain visible and must not be interrupted by the normal timeout")
print("PASS: visible 429 status and respect for server-directed backoff")

// Pending snapshots survive restarts; a failed operation cannot silently drop another shot.
let queueDirectory = root.appendingPathComponent("pending")
let queue = QueueStore(directory:queueDirectory)
try check(try queue.load().isEmpty,"New queue must be empty")
let shot1 = try queue.add(image)
let shot2 = try queue.add(image)
let restoredQueue = QueueStore(directory:queueDirectory)
let restoredShots = try restoredQueue.load()
try check(restoredShots.map(\.id) == [shot1.id,shot2.id],"Queued images must preserve order across restarts")
try check(FileManager.default.fileExists(atPath:restoredQueue.url(for:shot1).path),"Queued originals must remain available")
let invalidImage = root.appendingPathComponent("bad.png"); try Data("not an image".utf8).write(to:invalidImage)
var invalidRejected = false
 do { _ = try restoredQueue.add(invalidImage) } catch { invalidRejected = true }
try check(invalidRejected && restoredQueue.shots.count == 2,"Invalid inputs must not alter queued originals")
try restoredQueue.remove([shot1.id])
try check(restoredQueue.shots.map(\.id) == [shot2.id],"Removing a shot must preserve the remaining queue")
try check(!FileManager.default.fileExists(atPath:restoredQueue.url(for:shot1).path),"Removed shot should no longer occupy disk")
let queuePermission = try FileManager.default.attributesOfItem(atPath:restoredQueue.url(for:shot2).path)[.posixPermissions] as? NSNumber
try check(queuePermission?.intValue == 0o600,"Queued screenshots must be private")
let brokenQueue = QueueStore(directory:root.appendingPathComponent("broken-queue"))
try FileManager.default.createDirectory(at:brokenQueue.directory,withIntermediateDirectories:true)
try Data("broken".utf8).write(to:brokenQueue.manifest)
var preserved = false
 do { _ = try brokenQueue.add(image) } catch { preserved = true }
try check(preserved && (try Data(contentsOf:brokenQueue.manifest)) == Data("broken".utf8),"An unreadable queue manifest must not be overwritten")
let batch = BatchAnswer(items:[BatchItem(image_index:2,part_index:1,result:b),BatchItem(image_index:1,part_index:1,result:a)])
let ordered = try batch.validated(imageCount:2)
try check(ordered.items.map(\.result.answer) == ["25.00","C"],"Batch answers must follow screenshot order")
for malformed in [BatchAnswer(items:[BatchItem(image_index:1,part_index:1,result:a)]),BatchAnswer(items:[BatchItem(image_index:1,part_index:1,result:a),BatchItem(image_index:1,part_index:1,result:b)]),BatchAnswer(items:[BatchItem(image_index:1,part_index:2,result:a),BatchItem(image_index:2,part_index:1,result:b)])] {
    var refused = false
    do { _ = try malformed.validated(imageCount:2) } catch { refused = true }
    try check(refused,"Missing, duplicate, and skipped batch indices must be rejected")
}
let archive = HistoryStore(directory:root.appendingPathComponent("batch-history"))
_ = try archive.append(a) // Optional batch field remains compatible with previous single-answer archives.
let savedBatch = try archive.append(ordered.summary,batch:ordered)
let savedItems = try HistoryStore(directory:archive.directory).load()
try check(savedItems.count == 2 && savedItems[0].batch == nil && savedItems[1].batch?.items.count == 2,"Old and batch entries must coexist and survive restart")
try check(savedBatch.answer.answer == "1. 25.00\n2. C","Batch copy summary must preserve all exact answers")
let encodedBatch = String(data:try JSONEncoder().encode(batch),encoding:.utf8)!
let callFile = root.appendingPathComponent("batch-calls")
let batchExecutable = root.appendingPathComponent("batch-cli")
let script = """
#!/bin/sh
images=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift; output="$1" ;;
    --image) shift; test -f "$1" || exit 9; images=$((images+1)) ;;
  esac
  shift
done
test "$images" = 2 || exit 8
printf '%s\\n' "$images" >> "\(callFile.path)"
cat > "$output" <<'JSON'
\(encodedBatch)
JSON
printf '%s\\n' '{"type":"turn.completed"}'
"""
try script.write(to:batchExecutable,atomically:true,encoding:.utf8)
try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:batchExecutable.path)
let oneRequest = try Solver(executable:batchExecutable,connection:{ true }).solveBatch(images:[image,image],instructions:"")
let calls = try String(contentsOf:callFile,encoding:.utf8).split(separator:"\n")
try check(calls.count == 1 && oneRequest.items.map(\.result.answer) == ["25.00","C"],"All images must be sent together in one CLI invocation")
try check(restoredQueue.shots.count == 1,"Inference must not remove pending snapshots before history is saved")
try restoredQueue.remove(Set(restoredQueue.shots.map(\.id)))
try check(try QueueStore(directory:queueDirectory).load().isEmpty,"Successful queue cleanup must persist")
print("PASS: persistent image queue, removal, invalid input, permissions, corruption protection, batch ordering/coverage, mixed history, one request for all images")

let unreadable = Answer(status:"needs_input",task:"Unreadable screenshot",answer:"",format_note:"",solution:"",warnings:["A clearer screenshot is needed"])
let partial = try BatchAnswer(items:[BatchItem(image_index:1,part_index:1,result:a),BatchItem(image_index:1,part_index:2,result:b),BatchItem(image_index:2,part_index:1,result:unreadable)]).validated(imageCount:2)
try check(partial.items.count == 3 && partial.summary.answer.hasSuffix("3. Needs clarification"),"Several questions per image and unreadable images must remain in the result list")
print("PASS: multiple questions per image and per-question needs_input without losing other answers")
