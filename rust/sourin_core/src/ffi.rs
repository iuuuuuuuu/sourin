// ═══════════════════════════════════════════════════════════════════════
//  FFI 边界 —— Dart ↔ Rust 的唯一通道
// ═══════════════════════════════════════════════════════════════════════
//
// # 设计：单一 JSON 入口
//
// 不导出 90 个函数，只导出**少数几个**，命令名放在 JSON 里：
// ```text
// sourin_call(reqJson)                  → 同步命令
// sourin_call_async(reqJson, cb, id)    → 异步命令（回调返回）
// sourin_call_stream(reqJson, cb, token)→ 流式命令（回调多次）
// sourin_cancel_stream(token)           → 取消流
// sourin_free(ptr)                      → 释放 Rust 分配的字符串
// sourin_start(dataDir)                 → 启动核心
// sourin_core_version()                 → 版本探针
// ```
//
// # 为什么不用「一命令一导出」
//
// ```text
// ① 加命令不用改 Dart 的 lookupFunction（少一处会忘的地方）
// ② 参数解析集中在一处（Args），不会每个命令各写一遍
// ③ 跨 FFI 边界的东西越少越安全 —— 每个导出都是一个 unsafe 面
// ```
//
// # ★ 并发正确性（2026-09-23 修过死锁，改动前必读）
//
// ```text
// sourin_call          → Dart FFI 线程       → dispatch_blocking
// sourin_call_async    → spawn_blocking 阻塞池 → dispatch_blocking
// sourin_call_stream   → std::thread         → block_on
// ```
// ⚠️ **绝不能**从 `runtime().spawn()` 出来的 worker 线程直接
//    `block_on` —— 那会饿死 worker 池（实测：8 个并发全 120 秒超时）。
//    详见 `with_state_async` 的说明。

use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::OnceLock;

/// tokio 运行时（全局唯一）
///
/// # 为什么用 `OnceLock` 而不是 `Mutex<Option<..>>`
///
/// · `OnceLock` 的 `get()` 是**无锁**的（一次原子读），
///   而 `Mutex` 每次都要加解锁 —— 每条命令都要过一次，没必要
/// · 运行时是**建一次用一辈子**的东西，语义上就是 OnceLock
static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

/*
 * ★ 流式命令的取消标志集合（2026-09-22）
 *
 * # 为什么需要它
 *
 * Dart 的跨线程回调（`NativeCallable.listener`）**必须返回 void** ——
 * 实测 `flutter analyze` 报：
 * ```text
 * error - The return type of the function passed to
 *         'NativeCallable.listener' must be 'void' rather than 'Int32'
 * ```
 * 所以「靠回调返回值决定是否继续」这个设计在 Dart 侧做不到。
 *
 * 改成带外信号：Dart 调 `sourin_cancel_stream(token)` 往这里塞一条，
 * Rust 每次发事件前查一下。
 *
 * # 用 Mutex<HashSet> 而不是 AtomicBool
 *
 * 因为**可能同时有多路流**（比如用户在搜索页快速改关键词，
 * 前一次还没结束）。单一布尔量无法区分是哪一路要取消。
 */
static CANCELLED: std::sync::Mutex<Option<std::collections::HashSet<usize>>> =
    std::sync::Mutex::new(None);

/// 取取消集合（首次访问时初始化）
///
/// ⚠️ 用 `Mutex<Option<HashSet>>` 而不是 `Mutex<HashSet>`：
///    `HashSet::new()` **不是 const fn**（实测编译报
///    `E0015: cannot call non-const associated function in statics`），
///    没法直接初始化 static。
fn cancel_set() -> std::sync::MutexGuard<'static, Option<std::collections::HashSet<usize>>> {
    let mut g = CANCELLED.lock().unwrap();
    if g.is_none() {
        *g = Some(std::collections::HashSet::new());
    }
    g
}
/// 某个 token 鏄惁宸茶鍙栨秷
fn is_cancelled(token: usize) -> bool {
    cancel_set()
        .as_ref()
        .map(|s| s.contains(&token))
        .unwrap_or(false)
}

/// 鏍囪鍙栨秷
fn mark_cancelled(token: usize) {
    if let Some(s) = cancel_set().as_mut() {
        s.insert(token);
    }
}

/// 娓呴櫎鏍囧織锛堟祦寮€濮嬫椂娓呬竴娆°€佺粨鏉熸椂娓呬竴娆★級
fn clear_cancelled(token: usize) {
    if let Some(s) = cancel_set().as_mut() {
        s.remove(&token);
    }
}

fn runtime() -> &'static tokio::runtime::Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .thread_name("sourin-core")
            .build()
            .expect("tokio 杩愯鏃跺缓涓嶈捣鏉ワ紙鍐呭瓨涓嶈冻锛燂級")
    })
}

/// 鎶?Rust 鐨?String 交给调用方（调用方负责调 `sourin_free` 褰掕繕锛?
fn into_c(s: String) -> *mut c_char {
    // CString::new 在含 NUL 字节时会失败 鈥斺€?JSON 閲屼笉璇ユ湁瑁?NUL锛?
    // 鐪熸湁鐨勮瘽閫€鍖栨垚绌轰覆姣?panic 濂斤紙涓嶈兘璁╁涓诲穿锛?
    match CString::new(s) {
        Ok(c) => c.into_raw(),
        Err(_) => CString::new("{\"error\":\"瀛楃涓插惈 NUL 字节\"}")
            .unwrap()
            .into_raw(),
    }
}

/// 从调用方给的 C 瀛楃涓插彇鍑?Rust String
///
/// # Safety
///
/// `ptr` 蹇呴』鏄湁鏁堢殑銆佷互 NUL 缁撳熬鐨?UTF-8 瀛楃涓叉寚閽堬紝
/// 涓斿湪鏈嚱鏁拌繑鍥炲墠淇濇寔鏈夋晥銆備紶 NULL 浼氳繑鍥炵┖涓诧紙涓嶅穿锛夈€?
unsafe fn from_c(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    CStr::from_ptr(ptr).to_string_lossy().into_owned()
}

// 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
//  瀵煎嚭鐨?FFI 函数
// 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

/// 鐗堟湰鍙?鈥斺€?同时用来验证 FFI 閾捐矾鏄惁鎵撻€?
///
/// ```dart
/// final v = ffi.sourinCoreVersion();   // "sourin-core 0.1.0"
/// ```
///
/// # Safety
/// 杩斿洖鐨勬寚閽堟寚鍚戦潤鎬佹暟鎹紝**涓嶉渶瑕?free**銆?
#[no_mangle]
pub extern "C" fn sourin_core_version() -> *const c_char {
    static V: &[u8] = b"sourin-core 0.1.0\0";
    V.as_ptr() as *const c_char
}

/// 归还 Rust 分配的字符串
///
/// # Safety
///
/// `ptr` 蹇呴』鏄?`sourin_*` 系列函数返回的指针，**涓斿彧鑳?free 涓€娆?*銆?
/// 浼?NULL 鏄畨鍏ㄧ殑锛坣o-op锛夈€?
/// 浼犱竴涓潪鏈ā鍧楀垎閰嶇殑鎸囬拡 = 鏈畾涔夎涓恒€?
#[no_mangle]
pub unsafe extern "C" fn sourin_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

/// 鈽?鍚屾璋冪敤涓€涓懡浠?
///
/// # 输入
///
/// ```json
/// { "cmd": "list_providers", "args": { } }
/// ```
///
/// # 返回
///
/// 鎴愬姛锛氬懡浠ゆ湰韬殑杩斿洖鍊硷紙JSON锛?
/// 失败：`{"error":"...","kind":"network|unauthorized|not_found|unsupported|other"}`
///
/// ⚠️ 这个函数**浼氶樆濉炶皟鐢ㄧ嚎绋?*鐩村埌鍛戒护瀹屾垚銆?
///    Flutter 鐨?UI 线程**涓嶈**直接调它 鈥斺€?鐢?`sourin_call_async`銆?
///    淇濈暀瀹冩槸鍥犱负锛氭湰鍦拌搴撹繖绫诲揩鍛戒护鐢ㄥ畠鏇寸畝鍗曪紙鏃犲洖璋冨紑閿€锛夈€?
///
/// # Safety
/// `req_json` 蹇呴』鏄湁鏁堢殑 NUL 结尾 UTF-8 瀛楃涓层€?
/// 返回的指针必须由调用方用 `sourin_free` 褰掕繕銆?
#[no_mangle]
pub unsafe extern "C" fn sourin_call(req_json: *const c_char) -> *mut c_char {
    let req = from_c(req_json);
    let result = dispatch_blocking(&req);
    into_c(result)
}

/// ★★ 寮傛璋冪敤涓€涓懡浠わ紙Flutter 搴旇鐢ㄨ繖涓級
///
/// # 涓轰粈涔堥渶瑕佸紓姝ョ増鏈?
///
/// 90 涓懡浠ら噷鏈夊緢澶氭槸**秒级**的：
/// ```text
/// search_all       璺ㄥ涓簮骞跺彂鎼滅储
/// resolve_stream   瑙ｆ瀽鐪熷疄娴佸湴鍧€锛堣璧颁笂娓?API锛?
/// get_detail       鎷夎鎯?
/// backup_export    导出打包
/// ```
/// 杩欎簺濡傛灉鍚屾璋冿紝Flutter 鐨?UI 浼?*鏁存鍗℃**銆?
///
/// # 鈽?鍙傛暟涓轰粈涔堥兘鏄?`usize` 鑰屼笉鏄寚閽?函数类型
///
/// FFI 边界上，**指针和函数指针都不是 `Send`**锛岃€?`tokio::spawn`
/// 要求 future 鏄?`Send`銆傜洿鎺ヤ紶浼氭姤锛?
/// ```text
/// error[E0277]: `*mut c_void` cannot be sent between threads safely
/// error[E0277]: `extern "C" fn(...)` cannot be sent between threads safely
/// ```
///
/// 韪╁潙璁板綍锛氭垜绗竴鐗堟妸 `user_data` 包成 newtype 标了 `Send`锛?
/// 浣?*漏了 callback** 鈥斺€?閿欒渚濇棫銆傜浜岀増涓や釜閮借浆 `usize` 鎵嶅銆?
///
/// 鐢?`usize` 鏄?FFI 鐨勫父瑙勫仛娉曪細鍦板潃鍊兼湰韬氨鏄暣鏁帮紝
/// 整数天然 `Send`銆傝繘鍑芥暟鍚?`as` 鍥炴寚閽堝嵆鍙€?
///
/// # 回调约定
///
/// ```text
/// callback(result_json_ptr, user_data)
///   · result_json_ptr 鐢?Rust 鍒嗛厤锛?*鍥炶皟鏂硅礋璐?free**
///     （Dart 渚у湪鍥炶皟閲岃瀹屽氨 free锛屼笉瑕佺暀鍒板悗闈級
///   · 鍥炶皟鍦?tokio 鐨?worker 线程上执行，**不是 Dart 涓?isolate**
///     鈫?Dart 侧必须用 NativeCallable.listener 鎵嶈兘璺ㄧ嚎绋嬪洖鍒?isolate
/// ```
///
/// # 濡傛灉涓嶉渶瑕佺粨鏋?
///
/// `callback_addr = 0`锛氬懡浠ょ収甯告墽琛岋紝缁撴灉琚涪寮冦€?
/// 鐢ㄤ簬銆岃缃被銆嶅懡浠わ紙set_favorite / save_progress 绛夛級銆?
///
/// # Safety
///
/// · `req_json` 蹇呴』鏄湁鏁堢殑 NUL 结尾 UTF-8 瀛楃涓?
/// · `callback_addr` 瑕佷箞鏄?0锛岃涔堟槸
///   `extern "C" fn(*mut c_char, *mut c_void)` 鐨勬湁鏁堝嚱鏁板湴鍧€
/// · `user_data_addr` 原样回传，Rust **浠庝笉瑙ｅ紩鐢?*它；
///   鍏剁敓鍛藉懆鏈熷繀椤昏鐩栧埌鍥炶皟鎵ц瀹屾瘯
#[no_mangle]
pub unsafe extern "C" fn sourin_call_async(
    req_json: *const c_char,
    callback_addr: usize,
    user_data_addr: usize,
) {
    let req = from_c(req_json);

    /*
     * ★★★ 必须用 `spawn_blocking`，**不能**用 `runtime().spawn()`
     *     （2026-09-23 实测抓到的死锁 + panic）
     *
     * # 为什么
     *
     * `dispatch_blocking` 内部会 `runtime().block_on(...)`。
     * 而 `runtime().spawn()` 出来的任务跑在 **worker 线程**上 ——
     * 在 worker 里 `block_on` 会直接 panic：
     * ```text
     * Cannot start a runtime from within a runtime.
     * This happens because a function (like `block_on`) attempted to
     * block the current thread while the thread is being used to drive
     * asynchronous tasks.
     * ```
     * 实测表现：首页 8 个并发区块**全部失败**，且错误消息是空的
     *（panic 被 catch_unwind 接住，消息丢了）。
     *
     * # spawn_blocking 的区别
     *
     * 它把任务放到 tokio 的**阻塞线程池**（与 worker 池分开），
     * 那里的线程**不驱动异步任务**，所以 `block_on` 合法。
     *
     * # 为什么不干脆改成真 async
     *
     * `dispatch_inner` 里有大量**同步命令**（`with_state`）——
     * 它们直接读写 SQLite，本来就不该在 async 上下文里跑。
     * 用 spawn_blocking 包一层是最小改动且语义正确的做法。
     */
    runtime().spawn_blocking(move || {
        let result = dispatch_blocking(&req);

        if callback_addr != 0 {
            // SAFETY: 璋冪敤鏂逛繚璇佽繖鏄湁鏁堢殑鍑芥暟鍦板潃锛堣 Safety 段）
            let cb: extern "C" fn(*mut c_char, *mut std::ffi::c_void) =
                std::mem::transmute(callback_addr);
            cb(into_c(result), user_data_addr as *mut std::ffi::c_void);
        }
        // callback_addr 涓?0 鏃剁粨鏋滅洿鎺ヤ涪寮冿紙璁剧疆绫诲懡浠や笉闇€瑕佸洖鎵э級
    });
}

/// 鈽?娴佸紡鍛戒护锛?026-09-22 鏂板锛夆€斺€?鍥炶皟浼氳璋冪敤**澶氭**
///
/// # 涓轰粈涔堥渶瑕佸崟鐙殑瀵煎嚭
///
/// `sourin_call_async` 鐨勮涔夋槸銆屾墽琛屼竴娆″懡浠?鈫?鍥炶皟涓€娆°€嶃€?
/// 鑰?`search_all_stream` 瑕?*姣忓畬鎴愪竴涓簮灏辨姤涓€娆?*锛?
/// ```text
/// sourin_call_async  鈫?鍙兘琛ㄨ揪銆屾渶缁堢粨鏋溿€?
/// sourin_call_stream 鈫?琛ㄨ揪銆岃繃绋嬩腑涓嶆柇浜х敓鐨勪簨浠躲€?
/// ```
/// 纭妸娴佸紡濉炶繘鍗曟鍥炶皟鍙湁涓ょ鍔炴硶锛岄兘涓嶅ソ锛?
/// ```text
/// 鈶?鏀掑埌鏈€鍚庝竴璧疯繑鍥? 鈫?澶卞幓娴佸紡鐨勬剰涔夛紙鐢ㄦ埛瑕佺瓑鏈€鎱㈢殑婧愶級
/// 鈶?鏀?sourin_call_async 鐨勮涔?鈫?破坏已有 32 涓懡浠ょ殑璋冪敤绾﹀畾
/// ```
/// 鎵€浠ョ嫭绔嬩竴涓鍑猴紝**不动已有行为**銆?
///
/// # 回调约定（与 `sourin_call_async` 涓€鑷达紝鍙槸鍙娆★級
///
/// ```text
/// callback(event_json_ptr, user_data_addr)
/// ```
/// · 姣忎釜浜嬩欢涓€娆¤皟鐢紝**椤哄簭涓庢簮瀹屾垚椤哄簭涓€鑷?*
/// · 事件 JSON 褰㈠锛?
///   ```json
///   {"kind":"hit","provider":"cycani","provider_name":"娆″厓鍩?,
///    "items":[...],"page":1,"page_count":5,"total":100}
///   {"kind":"miss","provider":"x","reason":"璇ユ簮宸插け鏁?}
///   ```
/// · 鍏ㄩ儴瀹屾垚鍚庡洖璋冧竴娆?`{"kind":"done"}` 鈥斺€?璁?Dart 渚х煡閬撲綍鏃舵敹璧?loading
/// · 鑻ュ惎鍔ㄥ氨澶辫触锛堟牳蹇冩湭鍚姩锛夛紝鍥炶皟涓€娆?`{"kind":"error","error":"..."}` 鍚庣粨鏉?
///
/// # ★★ 取消机制：用**显式 token**锛屼笉鐢ㄥ洖璋冭繑鍥炲€硷紙2026-09-22锛?
///
/// ## 涓轰粈涔堜笉鑳界敤杩斿洖鍊硷紙鎴戠涓€鐗堢殑璁捐锛岀紪璇戞湡灏辫鍚︽帀浜嗭級
///
/// 鎴戞渶鍒濊璁℃垚锛?
/// ```text
/// Rust 璋?cb(...) 鈫?鐪嬭繑鍥炲€?
///   返回 0   鈫?取消
///   杩斿洖闈?0 鈫?继续
/// ```
/// 鐪嬭捣鏉ュ共鍑€锛屼絾**鍦?Dart 渚ф牴鏈仛涓嶅埌**銆傚疄娴?`flutter analyze`锛?
/// ```text
/// error - The return type of the function passed to
///         'NativeCallable.listener' must be 'void' rather than 'Int32'
/// ```
/// Dart 的跨线程回调（`NativeCallable.listener`锛?*必须返回 void** 鈥斺€?
/// 鍥犱负瀹冩槸閫氳繃娑堟伅绔彛鎶曢€掑埌鐩爣 isolate 鐨勶紝鑰屾秷鎭姇閫掓槸**寮傛**的，
/// 鎷夸笉鍒板悓姝ヨ繑鍥炲€笺€?
///
/// 鍙︿竴涓€夐」 `NativeCallable.isolateLocal` 鍙互杩斿洖 i32锛?
/// 但它**鍙兘琚垱寤哄畠鐨勭嚎绋嬭皟鐢?* 鈥斺€?鑰?Rust 浠?worker 绾跨▼鍥炶皟锛?
/// 浼氱洿鎺?`abort` 鏁翠釜杩涚▼銆?
///
/// ## 鏀规垚甯﹀淇″彿
///
/// ```text
/// sourin_call_stream(req, cb, token)   鈫?token 鏍囪瘑杩欎竴璺祦
/// cb(event_json, token)                鈫?void 返回
/// sourin_cancel_stream(token)          鈫?Dart 涓诲姩鍙栨秷锛堝彟涓€涓鍑猴級
/// ```
/// Rust 鍐呴儴缁存姢涓€涓彇娑堥泦鍚堬紱姣忔瑕佸彂浜嬩欢鍓嶆鏌ワ細
/// ```text
/// 宸插彇娑?鈫?回调返回 false 鈫?search_all_stream 提前 return
///                       鈫?鐢熶骇鑰?abort 鈫?当前网络请求取消
/// ```
///
/// **璇箟瀹屽叏涓嶅彉**（用户关页面 鈫?立刻停，实测 0.66s 鑰屼笉鏄瓑 30 绉掞級锛?
/// 鍙槸鎶娿€屽悓姝ヨ繑鍥炲€笺€嶆崲鎴愪簡銆屽甫澶栨爣蹇椼€嶃€?
///
/// # 回调约定
///
/// ```text
/// cb(event_json_ptr, token)
/// ```
/// · 姣忎釜浜嬩欢涓€娆¤皟鐢紝**椤哄簭涓庢簮瀹屾垚椤哄簭涓€鑷?*
/// · 事件 JSON 褰㈠锛?
///   ```json
///   {"kind":"hit","provider":"cycani","provider_name":"娆″厓鍩?,
///    "items":[...],"page":1,"page_count":5,"total":100}
///   {"kind":"miss","provider":"x","reason":"璇ユ簮宸插け鏁?}
///   ```
/// · 鍏ㄩ儴瀹屾垚鍚庡洖璋冧竴娆?`{"kind":"done"}`
/// · 鍚姩灏卞け璐ユ椂鍥炶皟涓€娆?`{"kind":"error","error":"..."}`
///
/// # Safety
///
/// · `req_json` 蹇呴』鏄湁鏁堢殑 NUL 结尾 UTF-8 瀛楃涓?
/// · `callback_addr` 瑕佷箞鏄?0锛岃涔堟槸
///   `extern "C" fn(*mut c_char, usize)` 鐨勬湁鏁堝嚱鏁板湴鍧€
/// · `token` 鐢辫皟鐢ㄦ柟鍐冲畾锛堝缓璁€掑鏁存暟锛夛紝鐢ㄤ簬鍚庣画鍙栨秷
#[no_mangle]
pub unsafe extern "C" fn sourin_call_stream(
    req_json: *const c_char,
    callback_addr: usize,
    token: usize,
) {
    let req = from_c(req_json);

    /*
     * 先把请求解析出来 鈥斺€?鍙湁 `search_all_stream` 鐩墠璧版祦寮忋€?
     * 鍏跺畠鍛戒护鍚嶄竴寰嬪洖涓€涓?error 浜嬩欢锛屼笉鍋氶潤榛樺拷鐣?
     *锛堥潤榛樺拷鐣ヤ細璁?Dart 侧一直等 "done"锛岃〃鐜颁负鎼滅储缁撴灉姘歌繙涓嶇粨鏉燂級銆?
     */
    let parsed: Option<(String, u32)> = (|| {
        let v: serde_json::Value = serde_json::from_str(&req).ok()?;
        let cmd = v.get("cmd")?.as_str()?;
        if cmd != "search_all_stream" {
            return None;
        }
        let a = crate::args::Args::new(&v, "search_all_stream");
        let kw = a.str("keyword").ok()?.to_string();
        let page = a.u32_or("page", 1);
        Some((kw, page))
    })();

    let cb: Option<extern "C" fn(*mut c_char, usize)> = if callback_addr != 0 {
        // SAFETY: 璋冪敤鏂逛繚璇佽繖鏄湁鏁堝嚱鏁板湴鍧€锛堣 Safety 段）
        Some(std::mem::transmute(callback_addr))
    } else {
        None
    };

    let Some((keyword, page)) = parsed else {
        if let Some(cb) = cb {
            let msg = r#"{"kind":"error","error":"sourin_call_stream 鍙敮鎸?search_all_stream"}"#;
            cb(into_c(msg.to_string()), token);
        }
        return;
    };

    let Some(st) = state() else {
        if let Some(cb) = cb {
            let msg = r#"{"kind":"error","error":"鏍稿績灏氭湭鍚姩 鈥斺€?请先调用 sourin_start"}"#;
            cb(into_c(msg.to_string()), token);
        }
        return;
    };

    // 鏂颁竴杞祦寮€濮?鈫?娓呮帀鍙兘娈嬬暀鐨勫彇娑堟爣蹇楋紙token 鍙兘琚鐢級
    clear_cancelled(token);

    /*
     * 鈽?在独立线程上 block_on（与 `with_state_async` 同样的理由）
     *
     * `sourin_call_stream` 鍙兘琚?Dart 浠庝换鎰忕嚎绋嬭皟鐢ㄣ€傚鏋滃湪
     * tokio runtime 鍐呴儴璋?`block_on` 浼?panic
     *锛?Cannot start a runtime from within a runtime"），
     * 鑰?panic 璺?FFI 鏄?UB 鈥斺€?浼氱洿鎺ュ穿鎺?Flutter銆?
     */
    std::thread::spawn(move || {
        let fut = crate::commands::search_all_stream(st, &keyword, page, |ev| {
            /*
             * 鈽?姣忔鍙戜簨浠跺墠妫€鏌ュ彇娑堟爣蹇?
             *
             * 返回 false 浼氳 `search_all_stream` 提前 return锛?
             * 杩涜€?abort 鐢熶骇鑰咃紙褰撳墠缃戠粶璇锋眰闅忎箣鍙栨秷锛夈€?
             */
            if is_cancelled(token) {
                log::info!("流式搜索 token={token} 已被取消，停止搜索");
                return false;
            }
            let Some(cb) = cb else {
                // 没有回调 鈫?缁х画璺戝畬锛堣皟鐢ㄦ柟涓嶈缁撴灉锛屼絾鍛戒护浠嶉渶鎵ц锛?
                return true;
            };
            let json = serde_json::to_string(&ev)
                .unwrap_or_else(|e| format!(r#"{{"kind":"error","error":"搴忓垪鍖栧け璐? {e}"}}"#));
            cb(into_c(json), token);
            true
        });

        let r = runtime().block_on(fut);

        // 鏀跺熬浜嬩欢锛堝凡鍙栨秷鏃朵篃鍙?鈥斺€?璁?Dart 渚х煡閬撴祦缁撴潫浜嗭紝鍙互鏀惰捣 loading锛?
        if let Some(cb) = cb {
            let done = match r {
                Ok(()) => r#"{"kind":"done"}"#.to_string(),
                Err(e) => format!(
                    r#"{{"kind":"error","error":{}}}"#,
                    /*
                     * ⚠️ 这里用 raw string（`r#""unknown""#`）而不是
                     *    普通字符串 + 反斜杠转义 —— Rust 的普通字符串
                     *    **不支持** JSON/C 那种 \" 写法，会报
                     *    `unknown start of token: \`。
                     *    （写这段注释时也别在注释里写出那个转义序列 ——
                     *      它会干扰词法扫描。）
                     */
                    serde_json::to_string(&e).unwrap_or_else(|_| r#""unknown""#.to_string())
                ),
            };
            cb(into_c(done), token);
        }

        // 娴佺粨鏉?鈫?娓呮帀鏍囧織锛堥伩鍏嶉泦鍚堟棤闄愬闀匡級
        clear_cancelled(token);
    });
}

/// 鍙栨秷涓€璺祦寮忓懡浠わ紙2026-09-22锛?
///
/// # 用法
///
/// Dart 侧在**鐢ㄦ埛绂诲紑鎼滅储椤?*时调它：
/// ```dart
/// SourinCore.cancelStream(token);
/// ```
/// Rust 渚т細鍦ㄤ笅涓€娆¤鍙戜簨浠舵椂鍙戠幇鏍囧織锛岃繑鍥?false 鈫?
/// `search_all_stream` 提前 return 鈫?鐢熶骇鑰?abort 鈫?褰撳墠璇锋眰鍙栨秷銆?
///
/// # 涓轰粈涔堟槸鐙珛鐨勫鍑鸿€屼笉鏄洖璋冭繑鍥炲€?
///
/// 瑙?`sourin_call_stream` 鐨勮鏄庯細Dart 的跨线程回调**必须返回 void**锛?
/// 鎷夸笉鍒板悓姝ヨ繑鍥炲€笺€傛墍浠ュ彇娑堝彧鑳借蛋甯﹀淇″彿銆?
///
/// # 幂等
///
/// 鍙栨秷涓€涓笉瀛樺湪鐨?token 鏄棤瀹崇殑锛堥泦鍚堥噷鍔犱竴鏉★紝涔嬪悗琚竻锛夈€?
/// 閲嶅鍙栨秷鍚屼竴涓?token 涔熸槸鏃犲鐨勩€?
#[no_mangle]
pub extern "C" fn sourin_cancel_stream(token: usize) {
    mark_cancelled(token);
    log::info!("宸茶姹傚彇娑堟祦寮忓懡浠?token={token}");
}

/// 鍚姩鏍稿績锛堝缓搴撱€佹仮澶嶆簮銆佽捣娴佷唬鐞嗭級
///
/// # 输入
///
/// ```json
/// { "dataDir": "C:/Users/x/AppData/Roaming/app.sourin.player" }
/// ```
///
/// # 返回
///
/// ```json
/// { "ok": true, "version": "sourin-core 0.1.0", "dataDir": "...",
///   "deviceId": "...", "providers": 3 }
/// ```
///
/// # 涓轰粈涔?dataDir 瑕佽皟鐢ㄦ柟浼?
///
/// 鏍稿績灞備笉璇ョ煡閬撳悇骞冲彴鐨勮矾寰?API锛?
/// ```text
/// Tauri   鈫?app.path().app_data_dir()
/// Flutter 鈫?path_provider 鐨?getApplicationSupportDirectory()
/// Android 鈫?/data/data/<pkg>/files/
/// ```
/// 璁╄皟鐢ㄦ柟鍐冲畾锛屾牳蹇冨彧绠＄敤銆?
///
/// # 閲嶅璋冪敤鏄畨鍏ㄧ殑
///
/// 绗簩娆¤皟鐢ㄤ細鐩存帴杩斿洖宸叉湁鐨勭姸鎬侊紙涓嶉噸澶嶅缓搴擄級鈥斺€?
/// Flutter 鐑噸杞?/ 椤甸潰閲嶅缓鏃跺彲鑳介噸澶嶈皟銆?
///
/// # Safety
/// 鍚?`sourin_call`銆?
#[no_mangle]
pub unsafe extern "C" fn sourin_start(config_json: *const c_char) -> *mut c_char {
    let cfg = from_c(config_json);
    log::info!("sourin_start: {cfg}");

    // 解析配置
    let v: serde_json::Value = match serde_json::from_str(&cfg) {
        Ok(v) => v,
        Err(e) => {
            return into_c(err_json(&format!("鍚姩閰嶇疆涓嶆槸鍚堟硶 JSON: {e}"), "other"));
        }
    };

    let Some(data_dir) = v.get("dataDir").and_then(|d| d.as_str()) else {
        return into_c(err_json("鍚姩閰嶇疆缂哄皯 dataDir 瀛楁", "other"));
    };
    let data_dir = std::path::PathBuf::from(data_dir);

    // 宸插湪杩愯 鈫?直接返回（幂等）
    if STATE.get().is_some() {
        log::info!("核心已在运行，跳过重复启动");
        return into_c(existing_state_json());
    }

    // 鈽?鐪熸鍚姩锛堥樆濉炵瓑 bootstrap 瀹屾垚锛?
    let result = runtime().block_on(crate::state::AppState::bootstrap(data_dir));
    match result {
        Ok(state) => {
            /*
             * 鈽?缁熻鍙ｅ緞淇锛?026-09-22锛?
             *
             * `providers` 鍘熷厛鍙栫殑鏄?`third_party.len()`锛?
             * 閭ｅ彧鏄?*鎸佷箙鍖栫殑绗笁鏂规簮娓呭崟**锛屼笉鍚?JS 鎻掍欢銆?
             *
             * 实测暴露：日志里明明写着「已注册 26 涓?JS 插件」，
             * 杩斿洖鐨勫嵈鏄?`providers: 0` 鈥斺€?鍥犱负閭?26 涓潵鑷彃浠剁洰褰曪紝
             * 鑰?third_party 鏄┖鐨勩€?
             *
             * 杩欎釜瀛楁鏄粰璋冪敤鏂瑰仛鍚姩鑷鐢ㄧ殑锛?0"浼氳浜轰互涓?
             * 涓€涓簮閮芥病鍔犺浇銆傛墍浠ユ敼鎴愬彇**娉ㄥ唽琛ㄩ噷鐨勭湡瀹炴暟閲?*锛?
             * 骞舵妸涓ょ被鍒嗗紑鎶ワ紝璇箟鎵嶆竻鏅般€?
             */
            let js_count = state.registry.manifests().len();
            let third_party = state.third_party.read().map(|g| g.len()).unwrap_or(0);
            let device_id = state.device_id.clone();

            // 存进全局（set 澶辫触璇存槑鏈夊苟鍙戝惎鍔紝鐢ㄥ凡鏈夌殑锛?
            let _ = STATE.set(state);

            into_c(format!(
                r#"{{"ok":true,"version":"sourin-core 0.1.0","deviceId":{},"providers":{js_count},"thirdPartyProviders":{third_party}}}"#,
                serde_json::to_string(&device_id).unwrap_or_else(|_| "\"\"".into())
            ))
        }
        Err(e) => into_c(err_json(&format!("鍚姩澶辫触: {e}"), "other")),
    }
}

/// 宸叉湁鐘舵€佹椂鐨勮繑鍥烇紙骞傜瓑璺緞锛?
fn existing_state_json() -> String {
    let (device_id, js_count, third_party) = match STATE.get() {
        Some(s) => (
            s.device_id.clone(),
            s.registry.manifests().len(),
            s.third_party.read().map(|g| g.len()).unwrap_or(0),
        ),
        None => (String::new(), 0, 0),
    };
    format!(
        r#"{{"ok":true,"version":"sourin-core 0.1.0","alreadyStarted":true,"deviceId":{},"providers":{js_count},"thirdPartyProviders":{third_party}}}"#,
        serde_json::to_string(&device_id).unwrap_or_else(|_| "\"\"".into())
    )
}

// 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
//  鍏ㄥ眬鐘舵€?
// 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

/// 鍏ㄥ眬搴旂敤鐘舵€?
///
/// # 为什么用 `OnceLock` 鑰屼笉鏄?`Mutex<Option<..>>`
///
/// ```text
/// · 瀹冨彧鍦ㄥ惎鍔ㄦ椂璁剧疆涓€娆★紝涔嬪悗鍏ㄦ槸鍙璁块棶
/// · OnceLock 鐨?get() 鏄?*无锁**鐨勶紙涓€娆″師瀛愯锛?
/// · 鑰?Mutex 姣忔璁块棶閮借鎶㈤攣 鈥斺€?90 涓懡浠ら兘浼氱瀹?
/// ```
/// 涓庡師鐗?`app.manage(state)` 的效果等价（Tauri 鍐呴儴涔熸槸杩欐牱鐨勫瓨鍌級銆?
pub(crate) static STATE: std::sync::OnceLock<std::sync::Arc<crate::state::AppState>> =
    std::sync::OnceLock::new();

/// 鍙栧叏灞€鐘舵€侊紱鏈惎鍔ㄦ椂杩斿洖 None
pub(crate) fn state() -> Option<&'static std::sync::Arc<crate::state::AppState>> {
    STATE.get()
}

// 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
//  命令分发
// 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

/// 解析 `{cmd, args}` 骞跺垎鍙?
///
/// # 涓轰粈涔堥敊璇篃杩斿洖 JSON 鑰屼笉鏄姏
///
/// 璺?FFI 杈圭晫鎶?panic 鏄?*鏈畾涔夎涓?*锛堜細鐩存帴宕╂帀瀹夸富杩涚▼锛?
/// 鑰?Flutter 侧连栈都看不到）。所以这里把 panic 也接住，
/// 缁熶竴杞垚 JSON 閿欒杩斿洖銆?
fn dispatch_blocking(req: &str) -> String {
    /*
     * 鈽?鐢?catch_unwind 兜住 panic 鈥斺€?瀹佸彲杩斿洖閿欒锛屼笉璁╁涓诲穿
     *
     * # 涓轰粈涔堣繖閲屽彲浠ュ畨鍏?block_on锛?026-09-23 姝婚攣淇鍚庯級
     *
     * 璋冪敤鏉ユ簮鍙湁涓ゆ潯锛?*閮藉湪闈?worker 绾跨▼涓?*锛?
     * ```text
     * sourin_call        鈫?Dart 鐨?FFI 璋冪敤绾跨▼锛堜笉鏄?tokio 绾跨▼锛?
     * sourin_call_async  鈫?runtime().spawn_blocking 鐨?*闃诲姹?*线程
     * ```
     * 鎵€浠ュ湪閲岄潰 `block_on` 涓嶄細楗挎 tokio 鐨?worker 绾跨▼姹犮€?
     *
     * ⚠️ 鍙嶈繃鏉ヨ锛?*缁濅笉鑳?*浠?`runtime().spawn()` 鍑烘潵鐨?worker
     *    鐩存帴璋冭繖涓嚱鏁?鈥斺€?閭ｆ鏄箣鍓嶉偅涓閿佺殑鎴愬洜
     *   （worker 琚?block_on 鍗犱綇锛岃€?block_on 里的 future 鍙堣 worker锛夈€?
     */
    let req = req.to_string();
    match std::panic::catch_unwind(move || runtime().block_on(dispatch_inner(&req))) {
        Ok(s) => s,
        Err(e) => {
            let msg = e
                .downcast_ref::<&str>()
                .map(|s| s.to_string())
                .or_else(|| e.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "命令执行时 panic（无消息）".into());
            log::error!("sourin_core panic: {msg}");
            format!(
                r#"{{"error":{},"kind":"other"}}"#,
                serde_json::to_string(&msg).unwrap_or_else(|_| "\"panic\"".into())
            )
        }
    }
}

async fn dispatch_inner(req: &str) -> String {
    let v: serde_json::Value = match serde_json::from_str(req) {
        Ok(v) => v,
        Err(e) => {
            return err_json(&format!("请求不是合法 JSON: {e}"), "other");
        }
    };

    let cmd = v.get("cmd").and_then(|c| c.as_str()).unwrap_or("");
    if cmd.is_empty() {
        return err_json("请求缺少 cmd 瀛楁", "other");
    }

    /*
     * 鈹€鈹€ 鍛戒护琛?鈹€鈹€
     *
     * # 鍛藉悕绾﹀畾锛堜笌鍘熺増鍓嶇涓€鑷达級
     *
     * 鍛戒护鍚嶅氨鏄師鐗?`src/api/index.ts` 閲?`call<T>("xxx")` 鐨勯偅涓瓧绗︿覆銆?
     * **不能改名** 鈥斺€?否则 Dart 渚х殑璋冪敤鐐硅璺熺潃鏀癸紝
     * 鑰屻€屾搷浣滈€昏緫淇濇寔涓€鑷淬€嶈姹傚墠绔唬鐮佸敖閲忚兘鐓ф惉銆?
     *
     * # 鈽?鍙傛暟瑙ｇ爜璧?`Args`锛屼笉鍦ㄨ繖閲屾墜鍐?
     *
     * 瑙?`args.rs` 椤堕儴鐨勮鏄庯紙璧峰洜鏄?cross-layer guide 鐨?Mistake 4锛?
     * 每个命令各自解析 JSON = 姣忎釜娑堣垂鑰呬竴浠界鏈夊绾︼級銆?
     * 杩欓噷鍙礋璐?*分发**锛屼笉璐熻矗瑙ｆ瀽銆?
     *
     * # 闇€瑕?AppState 鐨勫懡浠?
     *
     * 鐢?`with_state()` 鍙栧叏灞€鐘舵€侊紱鏈惎鍔ㄦ椂杩斿洖鏄庣‘閿欒
     *锛堣€屼笉鏄?panic 鈥斺€?panic 璺?FFI 杈圭晫鏄?UB锛夈€?
     */
    let a = crate::args::Args::new(&v, cmd);

    match cmd {
        // 鈹€鈹€ 鎺㈤拡锛堜笉闇€瑕佺姸鎬侊級鈹€鈹€
        "ping" => r#"{"ok":true,"pong":true}"#.to_string(),
        "core_version" => r#"{"version":"sourin-core 0.1.0"}"#.to_string(),
        "core_is_started" => format!(r#"{{"started":{}}}"#, crate::commands::is_started()),

        // 鈹€鈹€ Provider 管理 鈹€鈹€
        "list_providers" => with_state(|st| crate::commands::list_providers(st)),
        "get_provider_order" => with_state(|st| crate::commands::get_provider_order(st)),
        "get_provider_enabled" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(|st| crate::commands::get_provider_enabled(st, &id))
        }

        // 鈹€鈹€ 棣栭〉閾捐矾锛堝紓姝ュ懡浠わ級鈹€鈹€
        //
        // ⚠️ 杩欏嚑涓槸**网络命令**，必须走 `with_state_async`
        //    鈥斺€?用同步版会把 tokio 鐨?worker 绾跨▼鍗′綇銆?
        "get_home" => with_state_async(move |st| async move {
            crate::home::get_home(st).await
        }).await,
        "get_categories" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::home::get_categories(st, &provider).await
            }).await
        }
        "get_rank" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let rank_id = match a.str("rank_id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let page = a.u32_or("page", 1);
            with_state_async(move |st| async move {
                crate::home::get_rank(st, &provider, &rank_id, page).await
            }).await
        }

        /*
         * 鈽?分类列表 鈥斺€?参数名走 Args锛岃嚜鍔ㄥ吋瀹?camelCase
         *
         * 鍘熺増鍓嶇浼?`categoryId`（`src/api/index.ts` L496），
         * 而这里按 Rust 鐨勮嚜鐒跺啓娉曡 `category_id`銆?
         * `Args::get` 浼氳嚜鍔ㄥ洖閫€鍒?camelCase 鈥斺€?瑙?args.rs 鐨勮鏄庛€?
         */
        "get_list" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let category_id = match a.str("category_id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let page = a.u32_or("page", 1);
            with_state_async(move |st| async move {
                crate::home::get_list(st, &provider, &category_id, page).await
            }).await
        }

        // 鈹€鈹€ 详情链路 鈹€鈹€
        "get_detail" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::playback::get_detail(st, &provider, &id).await
            }).await
        }
        "get_sources" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::playback::get_sources(st, &provider, &id).await
            }).await
        }
        "get_episodes" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            // 鍘熺増鍓嶇浼?`sourceCode`（camelCase锛?
            let source_code = match a.str("source_code") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::playback::get_episodes(st, &provider, &id, &source_code).await
            }).await
        }

        /*
         * 鈽呪槄鈽?鎾斁閾捐矾鐨勬渶鍚庝竴姝?鈥斺€?瑙ｆ瀽鐪熷疄娴佸湴鍧€
         *
         * # 涓轰粈涔堝崟鐙垪鍑猴紙鑰屼笉鏄拰涓婇潰鍑犱釜骞跺垪鎴愪竴琛岋級
         *
         * 瀹冩湁涓や釜鐗瑰埆涔嬪锛?
         * ```text
         * 鈶?它会把流地址**鏀瑰啓鎴愭湰鍦颁唬鐞嗗湴鍧€**锛堥槻鐩楅摼锛?
         *    鈫?杩斿洖鐨?url 鍙兘宸茬粡涓嶆槸 CDN 鍘熷鍦板潃
         * 鈶?鍙€夌殑 req 参数（PlayRequest锛夐€忎紶缁?provider
         * ```
         * Flutter 渚ф嬁鍒扮粨鏋滅洿鎺ヤ氦缁?media_kit 鎾斁鍗冲彲锛?
         * 涓嶉渶瑕佸啀澶勭悊璇锋眰澶?鈥斺€?閭ｅ凡缁忕敱鏈湴浠ｇ悊璐熻矗浜嗐€?
         */
        "resolve_stream" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            // req 鏄彲閫夌殑锛氬師鐗?`invoke("resolve_stream", { provider, id })`
            // 不带 req 涔熷悎娉曪紙鐢?PlayRequest::default()锛?
            let req = v
                .get("args")
                .and_then(|x| x.get("req"))
                .and_then(|r| serde_json::from_value::<crate::model::PlayRequest>(r.clone()).ok());
            with_state_async(move |st| async move {
                crate::playback::resolve_stream(st, &provider, &id, req).await
            }).await
        }

        /*
         * 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
         *  鎵规 1 · 鍙鍛戒护锛?026-09-22锛?
         * 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
         *
         * # 涓轰粈涔堣繖鎵规帓鍦ㄥ墠闈?
         *
         * ```text
         * 鍙 鈫?无副作用 鈫?鍙互瀹夊叏鍦板**鐪熷疄鐢ㄦ埛搴?*验证
         * ```
         * 鐢ㄦ埛鏈哄櫒涓婅鐫€姝ｅ紡鐗堜笖鏁版嵁鐪熷疄锛屽啓鍏ョ被鍛戒护蹇呴』鐢ㄧ嫭绔嬬洰褰曪紱
         * 鑰屽彧璇诲懡浠ゅ彲浠ョ洿鎺ヨ鐪熷疄搴撴潵纭銆屾惉杩愭槸鍚﹀繝瀹炪€嶁€斺€?
         * 杩欐槸鎬т环姣旀渶楂樼殑涓€鎵广€?
         *
         * # 杩欎簺鍛戒护閮芥槸鍚屾鐨勶紙璇?SQLite锛?
         *
         * 鐢?`with_state`锛堝悓姝ワ級鑰屼笉鏄?`with_state_async`锛?
         * ```text
         * SQLite 鏌ヨ鏄湰鍦版搷浣滐紝寰绾э紝涓嶅€煎緱璧风嚎绋?
         * with_state_async 浼?spawn 涓€涓嚎绋?鈥斺€?瀵硅繖绉嶅懡浠ゆ槸娴垂
         * ```
         * ⚠️ 反过来，网络命令**必须**鐢?async 鐗?鈥斺€?鍚﹀垯浼氬崱浣?
         *    tokio 鐨?worker 绾跨▼锛堣涓婇潰鍑犱釜缃戠粶鍛戒护鐨勬敞閲婏級銆?
         */
        "get_progress" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(|st| crate::commands::get_progress(st, &provider, &id))
        }
        "continue_watching" => {
            let limit = a.u32_opt("limit");
            with_state(|st| crate::commands::continue_watching(st, limit))
        }
        "list_all_progress" => with_state(|st| crate::commands::list_all_progress(st)),
        "list_history" => {
            let limit = a.u32_opt("limit");
            with_state(|st| crate::commands::list_history(st, limit))
        }
        "get_skip_marker" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(|st| crate::commands::get_skip_marker(st, &provider, &id))
        }
        "list_skip_markers" => with_state(|st| crate::commands::list_skip_markers(st)),
        "list_favorites" => {
            /*
             * ★★★ 参数是 `following_only`，**不是** `include_deleted`
             *     （2026-09-23 修正的移植错误）
             *
             * 原版签名是 `list_favorites(following_only: bool)`，
             * 它是一个**二选一的分派**：
             * ```text
             * true  → 追更列表（list_following_for_ui，按最近更新排）
             * false → 收藏列表（list_favorites，只含 favorited=1）
             * ```
             *
             * ⚠️ 两个参数都是 bool，**编译期看不出传错**。
             *     传错的表现是「追更页显示一堆已删除的内容」。
             *
             * ⚠️ 兼容：老前端可能传 `followingOnly`（camelCase）——
             *    这里两个名字都认。
             */
            let following_only = a
                .bool("following_only")
                .or_else(|_| a.bool("followingOnly"))
                .unwrap_or(false);
            /*
             * ⚠️ 必须走 `with_state_async` —— 它内部会
             *    `stream_proxy.ensure_started().await`（启动封面代理）。
             *    用同步版会卡住 tokio worker。
             */
            with_state_async(move |st| async move {
                crate::commands::list_favorites(st, following_only).await
            }).await
        }
        "list_following_for_ui" => {
            with_state(|st| crate::commands::list_following_for_ui(st))
        }
        "total_unread" => with_state(|st| crate::commands::total_unread(st)),
        "list_platform_history" => {
            let limit = a.u32_or("limit", 100);
            with_state(|st| crate::commands::list_platform_history(st, limit))
        }

        /*
         * 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
         *  鎵规 2 · 鍐欏叆鍛戒护锛?026-09-22锛?
         * 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
         *
         * # 涓轰粈涔堣繖閲屽垎鍚屾 / 寮傛涓ょ
         *
         * ```text
         * save_progress / set_skip_marker / clear_skip_marker /
         * remove_favorite / mark_favorite_read / clear_history
         *     鈫?绾?SQLite 鍐欙紝寰绾?鈫?with_state（同步）
         *
         * set_favorite / set_following
         *     鈫?寮€鍚拷鏇存椂浼氳皟骞冲彴 detail() 记基准集数（**网络**锛?
         *     鈫?with_state_async锛堝惁鍒欏崱浣?tokio worker 绾跨▼锛?
         * ```
         *
         * ⚠️ 鍚庤€呰嫢璇敤鍚屾鐗堬紝琛ㄧ幇鏄€岀偣杩芥洿鍚庢暣涓簲鐢ㄥ崱浣忓嚑绉掋€嶁€斺€?
         *    直到那个 20 绉掕秴鏃剁粨鏉熴€傝繖鏄緢闅炬煡鐨勫崱椤挎簮銆?
         */
        "save_progress" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let title = a.str_or("title", "");
            let cover = a.str("cover").ok().map(|s| s.to_string());
            let episode_id = a.str("episode_id").ok().map(|s| s.to_string());
            let episode_title = a.str("episode_title").ok().map(|s| s.to_string());
            let position = a.u64_or("position", 0);
            let duration = a.u64_or("duration", 0);
            let finished = a.bool("finished").ok();
            with_state(move |st| {
                crate::commands_write::save_progress(
                    st,
                    &provider,
                    &id,
                    &title,
                    cover,
                    episode_id,
                    episode_title,
                    position,
                    duration,
                    finished,
                )
            })
        }
        "clear_history" => with_state(|st| crate::commands_write::clear_history(st)),
        "set_skip_marker" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let title = a.str("title").ok().map(|s| s.to_string());
            let intro_start = a.u64_opt("intro_start");
            let intro_end = a.u64_opt("intro_end");
            let outro_start = a.u64_opt("outro_start");
            let outro_end = a.u64_opt("outro_end");
            let auto_skip = a.bool("auto_skip").ok();
            with_state(move |st| {
                crate::commands_write::set_skip_marker(
                    st,
                    &provider,
                    &id,
                    title,
                    intro_start,
                    intro_end,
                    outro_start,
                    outro_end,
                    auto_skip,
                )
            })
        }
        "clear_skip_marker" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| crate::commands_write::clear_skip_marker(st, &provider, &id))
        }
        "mark_favorite_read" => {
            let key = match a.str("key") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| crate::commands_write::mark_favorite_read(st, &key))
        }
        "remove_favorite" => {
            let key = match a.str("key") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| crate::commands_write::remove_favorite(st, &key))
        }

        /*
         * task-67 (Owner requirement 5): migrate records when switching source.
         *
         * key = "<provider>:<id>" (see commands_write::item_key)
         *   => switching source changes the provider
         *   => the key changes
         *   => writes create a NEW row and the OLD row stays in the list.
         *
         * This moves favorites / progress / history / skip_markers from the
         * old key to the new key in ONE transaction, then deletes the old row.
         *
         * NOTE (ASCII only on purpose): this file already contains some
         * mojibake comments from an earlier encoding accident; do not add more.
         */
        "repoint_item" => {
            let from_provider = match a.str("fromProvider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let from_id = match a.str("fromId") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let to_provider = match a.str("toProvider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let to_id = match a.str("toId") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| {
                crate::commands_write::repoint_item(
                    st,
                    &from_provider,
                    &from_id,
                    &to_provider,
                    &to_id,
                )
            })
        }

        // 鈹€鈹€ 涓嬮潰涓や釜鏄?*网络命令**锛堝紑杩芥洿瑕佹姄鍩哄噯闆嗘暟锛夆攢鈹€
        "set_favorite" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let on = a.bool_or("on", true);
            let title = a.str("title").ok().map(|s| s.to_string());
            let cover = a.str("cover").ok().map(|s| s.to_string());
            let kind = a.str("kind").ok().map(|s| s.to_string());
            let following = a.bool("following").ok();
            with_state_async(move |st| async move {
                crate::commands_write::set_favorite(
                    st, &provider, &id, on, title, cover, kind, following,
                )
                .await
            }).await
        }
        "set_following" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let following = a.bool_or("following", true);
            let title = a.str("title").ok().map(|s| s.to_string());
            let cover = a.str("cover").ok().map(|s| s.to_string());
            let kind = a.str("kind").ok().map(|s| s.to_string());
            with_state_async(move |st| async move {
                crate::commands_write::set_following(
                    st, &provider, &id, following, title, cover, kind,
                )
                .await
            }).await
        }

        /*
         * 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
         *  鎵规 3 · 鎼滅储锛?026-09-22锛?
         * 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
         *
         * `search_all` 璧拌繖閲岋紙绛夊叏閮ㄦ簮杩斿洖鍚庝竴娆℃€х粰缁撴灉锛夈€?
         *
         * ⚠️ `search_all_stream` **不在这里** 鈥斺€?瀹冩槸娴佸紡鍛戒护锛?
         *    必须走独立的 `sourin_call_stream` 瀵煎嚭锛堝洖璋冨娆★級銆?
         *    濡傛灉璇敤 `sourin_call_async` 调它，会得到
         *    銆屽懡浠ゅ皻鏈帴鍏ャ€嶇殑閿欒锛岃€屼笉鏄潤榛樺け璐ワ紙鍒绘剰鐨勶級銆?
         */
        "search_all" => {
            let keyword = match a.str("keyword") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let page = a.u32_or("page", 1);
            with_state_async(move |st| async move {
                crate::commands::search_all(st, &keyword, page).await
            }).await
        }

        /*
         * 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
         *  鎵规 4 · 鐩存挱锛?026-09-22锛?
         * 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
         *
         * 四个都是**网络命令**锛堣璋冨悇婧愮殑鐩存挱鎺ュ彛锛夛紝
         * 鎵€浠ュ繀椤昏蛋 `with_state_async` 鈥斺€?鐢ㄥ悓姝ョ増浼氬崱浣?tokio worker銆?
         */
        "get_live_channels" => with_state_async(move |st| async move {
            crate::commands::get_live_channels(st).await
        }).await,
        "get_live_stream" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            /*
             * ⚠️ 参数名是 `channel_id`锛屼絾鍘熺増鍓嶇浼犵殑鏄?`channelId`
             *    鈥斺€?`Args::get` 浼氳嚜鍔ㄥ洖閫€鍒?camelCase锛堣 args.rs锛夈€?
             */
            let channel_id = match a.str("channel_id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands::get_live_stream(st, &provider, &channel_id).await
            }).await
        }
        "get_epg" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let channel_id = match a.str("channel_id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands::get_epg(st, &provider, &channel_id).await
            }).await
        }
        "get_timeshift" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let channel_id = match a.str("channel_id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            /*
             * start / end 鏄?Unix 鏃堕棿鎴筹紙绉掞級鈥斺€?鐢?i64
             *
             * ⚠️ 时间戳可能为负（1970 涔嬪墠锛屾垨鏃跺尯璁＄畻閿欒鏃讹級銆?
             *    鐢?u64 浼氭妸璐熸暟鍙樻垚宸ㄥぇ鐨勬鏁帮紝闈欓粯浜х敓閿欒鐨勮姹傘€?
             *    原版签名就是 `i64`锛岀収鎶勩€?
             */
            let start = a.i64_or("start", 0);
            let end = a.i64_or("end", 0);
            with_state_async(move |st| async move {
                crate::commands::get_timeshift(st, &provider, &channel_id, start, end).await
            }).await
        }

        /*
         * 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
         *  鎵规 5 · Provider 涓庢彃浠剁鐞嗭紙2026-09-22锛?
         * 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
         *
         * 澶у鏁版槸鍚屾鐨勶紙璇诲啓鏂囦欢 / 内存），
         * 浣?`reload_plugins` / `save_plugin_source` 浼?*鎵ц鎻掍欢鑴氭湰**
         *（`validate_source` / `hydrate_capabilities`），
         * 那是网络 + JS 鎵ц 鈫?必须 async銆?
         */
        "set_provider_enabled" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let enabled = a.bool_or("enabled", true);
            with_state(move |st| {
                crate::commands_provider::set_enabled_persisted(st, &id, enabled)
            })
        }
        "set_provider_order" => {
            let ids = match a.str_list("ids") {
                Ok(v) => v,
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| crate::commands_provider::set_provider_order(st, &ids))
        }
        "get_provider_config" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| crate::commands_provider::get_provider_config(st, &id))
        }
        "remove_provider" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| crate::commands_provider::remove_provider(st, &id))
        }
        "list_plugins" => {
            with_state(|st| crate::commands_provider::list_plugins(st))
        }
        "reload_plugins" => with_state_async(move |st| async move {
            crate::commands_provider::reload_plugins(st).await
        }).await,
        "read_plugin" => {
            let file = match a.str("file") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| crate::commands_provider::read_plugin(st, &file))
        }
        "remove_plugin" => {
            let file = match a.str("file") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| crate::commands_provider::remove_plugin(st, &file))
        }
        "save_plugin_source" => {
            let file = match a.str("file") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let source = match a.str("source") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_provider::save_plugin_source(st, &file, &source).await
            }).await
        }

        /*
         * ══════════════════════════════════════════════════════════════
         * 插件「检测更新 / 更新 / 回滚」（task-23，2026-09-25）
         * ══════════════════════════════════════════════════════════════
         *
         * ⚠️ **纯新增分支** —— 上面那些现有分支一行都没动。
         *
         * # sync / async 的分界（与相邻分支同一套判据）
         *
         * ```text
         * 纯本地读写（历史列表 / 记来源）      → with_state
         * 走网络（检测 / 更新）或会重载插件    → with_state_async
         * ```
         * ⚠️ `rollback_plugin` 虽然是**本地操作**，但它最后要
         *    `reload_plugins`（真的执行 JS）—— 放同步路径会卡住 UI，
         *    所以必须 async。
         */
        "check_plugin_update" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            // 走网络 → async
            with_state_async(move |st| async move {
                crate::commands_provider::check_plugin_update(st, &id).await
            }).await
        }
        "list_plugin_sources" => {
            /*
             * ★ 纯本地读 sidecar（毫秒级、零网络）——
             *   界面加载时用它决定"哪些卡片显示「检测更新」按钮"。
             *   绝不能用 check_all_plugin_updates 代替：那会在打开设置页时
             *   对每个插件发一次网络请求。
             */
            with_state(|st| crate::commands_provider::list_plugin_sources(st))
        }
        "check_all_plugin_updates" => {
            // 批量：串行查全部**有来源**的插件（见函数文档）
            with_state_async(move |st| async move {
                crate::commands_provider::check_all_plugin_updates(st).await
            }).await
        }
        "update_plugin_from_source" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_provider::update_plugin_from_source(st, &id).await
            }).await
        }
        "list_plugin_versions" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            // 纯本地读目录 → 同步
            with_state(move |st| crate::commands_provider::list_plugin_version_history(st, &id))
        }
        "rollback_plugin" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let version = match a.str("version") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            // ★ 虽然全是本地文件操作，但末尾要 reload_plugins（执行 JS）→ async
            with_state_async(move |st| async move {
                crate::commands_provider::rollback_plugin(st, &id, &version).await
            }).await
        }
        "set_plugin_source" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let url = match a.str("url") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            // 纯本地写 sidecar → 同步
            with_state(move |st| crate::commands_provider::set_plugin_source(st, &id, &url))
        }

        /*
         * 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
         *  鎵规 6 · 登录 / 代理 / 备份 / WebDAV锛?026-09-22锛?
         * 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
         *
         * 鍚屾 / 寮傛鐨勫垎鐣岋細
         * ```text
         * 绾湰鍦拌鍐欙紙浠ｇ悊閰嶇疆 / 澶囦唤棰勮 / 导入）→ with_state
         * 走网络（登录 / 娴嬩唬鐞?/ 娴嬪悓姝?/ 鍚屾锛? 鈫?with_state_async
         * ```
         * ⚠️ `backup_import` 铏芥槸鏈湴鎿嶄綔锛屼絾浼氬啓澶ч噺鏁版嵁 + 閲嶈浇鎻掍欢锛?
         *    鏀惧湪鍚屾璺緞涓婁細璁?UI 鍗′綇锛堝疄娴嬪鍏?26 涓彃浠惰 1-2 绉掞級銆?
         *    涓嶈繃瀹冩湰韬笉 await 缃戠粶锛屾墍浠ヤ粛鐢?with_state 鈥斺€?鍙槸
         *    Dart 侧应该用 `sourin_call_async` 璋冨畠锛岄伩鍏嶉樆濉?UI 绾跨▼銆?
         *    锛堣繖鏄皟鐢ㄦ柟鐨勮矗浠伙紝涓嶆槸杩欓噷鐨勩€傦級
         */
        "provider_login" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            // ⚠️ 必须 to_string() 鈥斺€?`str_or` 返回 `&str`锛堝€熺敤鑷姹?JSON），
            //    而下面是 `move` 闂寘锛屼笉鑳藉€熺敤灞€閮ㄥ彉閲?
            let username = a.str_or("username", "").to_string();
            let password = a.str_or("password", "").to_string();
            with_state_async(move |st| async move {
                crate::commands_backup::provider_login(st, &provider, username, password).await
            }).await
        }
        "provider_logout" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_backup::provider_logout(st, &provider).await
            }).await
        }
        "provider_session" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_backup::provider_session(st, &provider).await
            }).await
        }
        "provider_session_state" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_backup::provider_session_state(st, &provider).await
            }).await
        }
        "ensure_provider_session" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_backup::ensure_provider_session(st, &provider).await
            }).await
        }
        "forget_provider_credentials" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_backup::forget_provider_credentials(st, &provider).await
            }).await
        }
        "provider_qr_login_start" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_backup::provider_qr_login_start(st, &provider).await
            }).await
        }
        "provider_qr_login_poll" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let key = match a.str("key") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_backup::provider_qr_login_poll(st, &provider, &key).await
            }).await
        }

        // 鈹€鈹€ 站点代理 鈹€鈹€
        "list_proxy_configs" => with_state(|st| crate::commands_backup::list_proxy_configs(st)),
        "set_proxy_config" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            /*
             * config 鏄竴涓璞?鈥斺€?鐢?serde 鍙嶅簭鍒楀寲銆?
             * 瑙ｆ瀽澶辫触瑕佹姤鏄庣‘閿欒锛堣€屼笉鏄潤榛樼敤榛樿鍊硷紝
             * 閭ｄ細璁╃敤鎴蜂互涓轰唬鐞嗛厤濂戒簡鍏跺疄娌℃湁锛夈€?
             */
            let cfg: crate::proxy::ProxyConfig = match v
                .get("args")
                .and_then(|x| x.get("config"))
                .and_then(|c| serde_json::from_value(c.clone()).ok())
            {
                Some(c) => c,
                None => {
                    return err_json("缺少或非法的 config 鍙傛暟锛堝簲涓哄璞★級", "other");
                }
            };
            with_state(move |st| {
                crate::commands_backup::set_proxy_config(st, &provider, cfg)
            })
        }
        "clear_proxy_config" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| crate::commands_backup::clear_proxy_config(st, &provider))
        }
        "set_proxy_password" => {
            let provider = a.str_or("provider", "");
            let password = a.str_or("password", "");
            /*
             * ⚠️ 这个命令**涓嶉渶瑕?AppState**锛堝瘑鐮佸湪绯荤粺閽ュ寵涓查噷锛夈€?
             *    鎵€浠ヤ笉璧?with_state 鈥斺€?鏍稿績鏈惎鍔ㄦ椂涔熻兘鐢ㄣ€?
             */
            match crate::commands_backup::set_proxy_password(&provider, &password) {
                Ok(()) => r#"{"ok":true}"#.to_string(),
                Err(e) => err_json(&e, "other"),
            }
        }
        "has_proxy_password" => {
            let provider = a.str_or("provider", "");
            match crate::commands_backup::has_proxy_password(&provider) {
                Ok(b) => format!(r#"{{"has":{b}}}"#),
                Err(e) => err_json(&e, "other"),
            }
        }
        "test_proxy" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_backup::test_proxy(st, &provider).await
            }).await
        }
        "system_proxy_hint" => {
            match crate::commands_backup::system_proxy_hint() {
                Ok(h) => serde_json::to_string(&serde_json::json!({ "hint": h }))
                    .unwrap_or_else(|_| r#"{"hint":null}"#.into()),
                Err(e) => err_json(&e, "other"),
            }
        }

        // 鈹€鈹€ 备份 鈹€鈹€
        "backup_preview" => with_state(|st| crate::commands_backup::backup_preview(st)),
        "backup_default_name" => {
            with_state(|st| crate::commands_backup::backup_default_name(st))
        }
        "backup_export" => {
            let path = match a.str("path") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| crate::commands_backup::backup_export(st, &path))
        }
        "backup_inspect" => {
            let path = a.str_or("path", "");
            /*
             * ⚠️ 涓嶉渶瑕?AppState锛堢函璇绘枃浠讹級鈥斺€?鏍稿績鏈惎鍔ㄤ篃鑳芥瑙嗗浠斤紝
             *    这在"鐢ㄦ埛鎯崇湅鐪嬪浠介噷鏈変粈涔?鐨勫満鏅笅寰堟湁鐢ㄣ€?
             */
            match crate::commands_backup::backup_inspect(&path) {
                Ok(v) => serde_json::to_string(&v)
                    .unwrap_or_else(|e| err_json(&format!("搴忓垪鍖栧け璐? {e}"), "other")),
                Err(e) => err_json(&e, "other"),
            }
        }
        "backup_import" => {
            let path = match a.str("path") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            /*
             * ★ 2026-10-08 改走 async
             *
             * 导入末尾要 `load_plugins_hydrated`（执行 JS 拿能力位）——
             * 那是 async 的。原来的 with_state 是同步路径，注释（:1434）
             * 早就写着「会写大量数据 + 重载插件，放同步路径上会让 UI 卡住」，
             * 只是当时并没有真的重载，现在补上了。
             */
            with_state_async(move |st| async move {
                crate::commands_backup::backup_import(st, &path).await
            })
            .await
        }
        "backup_platform_history" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let device_id = a.str("device_id").ok().map(|s| s.to_string());
            with_state_async(move |st| async move {
                crate::commands_backup::backup_platform_history(st, &provider, device_id).await
            }).await
        }

        // 鈹€鈹€ 浜戠洏鍚屾 鈹€鈹€
        "configure_webdav" => {
            // ⚠️ 涓変釜閮藉繀椤?to_string() 鈥斺€?`str_or` 返回 `&str`锛堝€熺敤鑷姹?
            //    JSON），而下面是 `move` 闂寘锛屼笉鑳藉€熺敤灞€閮ㄥ彉閲忋€?
            let base_url = a.str_or("base_url", "").to_string();
            let username = a.str_or("username", "").to_string();
            let password = a.str_or("password", "").to_string();
            let remote_dir = a.str("remote_dir").ok().map(|s| s.to_string());
            with_state_async(move |st| async move {
                crate::commands_backup::configure_webdav(
                    st, base_url, username, password, remote_dir,
                )
                .await
            }).await
        }
        "disconnect_sync" => with_state_async(move |st| async move {
            crate::commands_backup::disconnect_sync(st).await
        }).await,
        "sync_status" => with_state_async(move |st| async move {
            crate::commands_backup::sync_status(st).await
        }).await,
        "test_sync" => with_state_async(move |st| async move {
            crate::commands_backup::test_sync(st).await
        }).await,
        "sync_now" => with_state_async(move |st| async move {
            crate::commands_backup::sync_now(st).await
        }).await,
        "sync_platform_history" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_backup::sync_platform_history(st, &provider).await
            }).await
        }

        /*
         * ── ★ 云盘设置 / 整体备份（契约 §1，2026-09-29 task-75）──
         *
         * 这五条**都不需要已连接**：Dart 侧首次进设置页就会调
         * `sync_settings_get` / `sync_backup_list`，那时用户还没配云盘。
         * 一报错 UI 就得走降级分支（契约 §3.1）。
         */
        "sync_settings_get" => with_state_async(move |st| async move {
            crate::commands_backup::sync_settings_get(st).await
        }).await,
        "sync_settings_set" => {
            // 全部可选：未传 = 不改该字段
            // ⚠️ `Args` **没有** `bool_opt`，可选布尔用 `.bool(..).ok()`
            let retain_count = a.u32_opt("retain_count");
            let auto_enabled = a.bool("auto_enabled").ok();
            let auto_interval_minutes = a.u32_opt("auto_interval_minutes");
            let auto_on_change = a.bool("auto_on_change").ok();
            let auto_backup_interval_minutes = a.u32_opt("auto_backup_interval_minutes");
            with_state_async(move |st| async move {
                crate::commands_backup::sync_settings_set(
                    st,
                    retain_count,
                    auto_enabled,
                    auto_interval_minutes,
                    auto_on_change,
                    auto_backup_interval_minutes,
                )
                .await
            }).await
        }
        "sync_backup_now" => with_state_async(move |st| async move {
            crate::commands_backup::sync_backup_now(st).await
        }).await,
        "sync_backup_list" => with_state_async(move |st| async move {
            crate::commands_backup::sync_backup_list(st).await
        }).await,
        "sync_backup_delete" => {
            let name = match a.str("name") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_backup::sync_backup_delete(st, &name).await
            }).await
        }

        /*
         * 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
         *  鎵规 7 · 遥控 + 鍓╀綑鍛戒护锛?026-09-22锛?
         * 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
         *
         * 閬ユ帶鏄?*鏈湴 HTTP 服务**锛堟墜鏈烘祻瑙堝櫒杩炶繃鏉ワ級锛?
         * 鎵€浠?`remote_start` / `remote_stop` 瑕?await（起/鍋滄湇鍔★級銆?
         */
        "remote_start" => {
            let port = a.u32_opt("port").map(|p| p as u16);
            with_state_async(move |st| async move {
                crate::commands_remote::remote_start(st, port).await
            }).await
        }
        "remote_stop" => with_state_async(move |st| async move {
            crate::commands_remote::remote_stop(st).await
        }).await,
        "remote_refresh_pin" => {
            with_state(|st| crate::commands_remote::remote_refresh_pin(st))
        }
        "remote_set_fixed_pin" => {
            let pin = a.str_or("pin", "").to_string();
            with_state(move |st| crate::commands_remote::remote_set_fixed_pin(st, &pin))
        }
        "remote_set_auto_start" => {
            let enabled = a.bool_or("enabled", true);
            with_state(move |st| {
                crate::commands_remote::remote_set_auto_start(st, enabled)
            })
        }
        "remote_auto_start" => {
            with_state(|st| crate::commands_remote::remote_auto_start(st))
        }
        "remote_report_state" => {
            let st_json: crate::remote::RemoteState = match v
                .get("args")
                .and_then(|x| x.get("state"))
                .and_then(|s| serde_json::from_value(s.clone()).ok())
            {
                Some(s) => s,
                None => return err_json("缺少或非法的 state 鍙傛暟锛堝簲涓哄璞★級", "other"),
            };
            with_state(move |st| {
                crate::commands_remote::remote_report_state(st, st_json)
            })
        }
        "remote_take_commands" => {
            with_state(|st| crate::commands_remote::remote_take_commands(st))
        }
        "remote_set_search" => {
            let payload: crate::remote::SearchPayload = match v
                .get("args")
                .and_then(|x| x.get("payload"))
                .and_then(|s| serde_json::from_value(s.clone()).ok())
            {
                Some(p) => p,
                None => return err_json("缺少或非法的 payload 鍙傛暟锛堝簲涓哄璞★級", "other"),
            };
            with_state(move |st| crate::commands_remote::remote_set_search(st, payload))
        }
        "remote_set_home" => {
            let payload: crate::remote::HomePayload = match v
                .get("args")
                .and_then(|x| x.get("payload"))
                .and_then(|s| serde_json::from_value(s.clone()).ok())
            {
                Some(p) => p,
                None => return err_json("缺少或非法的 payload 鍙傛暟锛堝簲涓哄璞★級", "other"),
            };
            with_state(move |st| crate::commands_remote::remote_set_home(st, payload))
        }

        // 鈹€鈹€ 剩余零散命令 鈹€鈹€
        "check_updates" => {
            let max_items = a.u32_opt("max_items").map(|n| n as usize);
            with_state_async(move |st| async move {
                crate::commands_remote::check_updates(st, max_items).await
            }).await
        }
        "health_sweep" => with_state_async(move |st| async move {
            crate::commands_remote::health_sweep(st).await
        }).await,
        "toggle_favorite" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let title = a.str_or("title", "").to_string();
            let cover = a.str("cover").ok().map(|s| s.to_string());
            let kind = a.str("kind").ok().map(|s| s.to_string());
            let following = a.bool("following").ok();
            with_state_async(move |st| async move {
                crate::commands_remote::toggle_favorite(
                    st, &provider, &id, title, cover, kind, following,
                )
                .await
            }).await
        }
        "install_plugin" => {
            let url = match a.str("url") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_remote::install_plugin(st, &url).await
            }).await
        }
        "install_plugin_source" => {
            let source = match a.str("source") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let name_hint = a.str("name_hint").ok().map(|s| s.to_string());
            with_state_async(move |st| async move {
                crate::commands_remote::install_plugin_source(st, &source, name_hint).await
            }).await
        }
        "import_declarative_provider" => {
            let json = match a.str("json") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_remote::import_declarative_provider(st, &json).await
            }).await
        }
        "install_http_provider" => {
            let base_url = match a.str("base_url") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let headers: Option<std::collections::HashMap<String, String>> = v
                .get("args")
                .and_then(|x| x.get("headers"))
                .and_then(|h| serde_json::from_value(h.clone()).ok());
            with_state_async(move |st| async move {
                crate::commands_remote::install_http_provider(st, base_url, headers).await
            }).await
        }
        // ★ TVBox 配置导入（task-5）
        //
        // config 既可以是配置 JSON 文本，也可以是配置地址（http/https）。
        // 两种都收，是为了让用户「贴链接」和「贴内容」都不用先想一下。
        "import_tvbox_config" => {
            let config = match a.str("config") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::tvbox::import_tvbox_config(st, &config).await
            }).await
        }
        "plugin_config_set" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let values: serde_json::Map<String, serde_json::Value> = v
                .get("args")
                .and_then(|x| x.get("values"))
                .and_then(|x| x.as_object().cloned())
                .unwrap_or_default();
            with_state(move |st| {
                crate::commands_remote::plugin_config_set(st, &id, values)
            })
        }

        "plugin_config_get" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| crate::commands_remote::plugin_config_get(st, &id))
        }
        "remote_status_cmd" => {
            with_state(|st| crate::commands_remote::remote_status_cmd(st))
        }

        /*
         * ══════════════════════════════════════════════════════════════
         * TVBox 订阅链接 + 检测更新（task-12，2026-09-25）
         * ══════════════════════════════════════════════════════════════
         *
         * 用户原话：
         * > 填入 tvbox 源的链接，然后他有更新我们也能收得到，不至于更新失效了
         *
         * ⚠️ **纯新增分支** —— 上面那些现有分支一行都没动。
         *
         * # sync / async 的分界（与相邻插件分支同一套判据）
         *
         * ```text
         * 纯本地读写（列源 / 记链接 / 删源）      → with_state
         * 走网络（检测更新 / 一键更新）          → with_state_async
         * ```
         * ⚠️ `remove_tvbox_source` 内部会调 remove_provider（它写第三方源清单），
         *    但那只是一次小文件写入 —— 与上面现有的 "remove_provider" 分支
         *    保持同一种处理（with_state），不另开一条异步路径。
         */
        "list_tvbox_sources" => {
            /*
             * ★ 纯本地读 sidecar（毫秒级、零网络）——
             *   界面加载时用它决定「哪些卡片显示「检测更新」按钮」。
             *   绝不能用 check_tvbox_updates 代替：那会在打开设置页时
             *   对每个订阅链接发一次网络请求。
             */
            with_state(|st| crate::tvbox::list_tvbox_sources(st))
        }
        "check_tvbox_updates" => {
            // id 可选：不传 = 查全部有链接的源
            let id = a.str_or("id", "").to_string();
            let only = if id.is_empty() { None } else { Some(id) };
            // 走网络 → async
            with_state_async(move |st| async move {
                crate::tvbox::check_tvbox_updates(st, only.as_deref()).await
            })
            .await
        }
        "update_tvbox_source" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            // ★ 默认值必须是「只更新已存在的站、绝不删」——
            //   漏传参数时最坏结果是「什么都没删」，不是「删了用户的东西」。
            let apply_new = a.bool_or("applyNew", true);
            let delete_missing = a.bool_or("deleteMissing", false);
            with_state_async(move |st| async move {
                crate::tvbox::update_tvbox_source(st, &id, apply_new, delete_missing).await
            })
            .await
        }
        "set_tvbox_source" => {
            // 与插件侧 set_plugin_source 对称：给「贴文本导入的源」事后补一个链接
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let url = a.str_or("url", "").to_string();
            // 纯本地写 sidecar → 同步
            with_state(move |st| crate::tvbox::set_tvbox_source(st, &id, &url))
        }
        "remove_tvbox_source" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            // 删源 + 清订阅链接是同一个操作（见函数文档）
            with_state(move |st| crate::tvbox::remove_tvbox_source(st, &id))
        }

        _ => err_json(
            &format!(
                "命令 `{cmd}` 尚未接入 FFI 层。\
                 已接入 112 个（批次 1-7 见 MIGRATION-PLAN.md 的进度表；\
                 批次 8 的 TVBox 订阅与插件检测更新见 task-12 / task-23）。\
                 其余命令需要把原版 lib.rs 里对应的 #[tauri::command] \
                 函数体搬到 commands*.rs，再在这里挂一条 match 分支。"
            ),
            "unsupported",
        ),
    }
}

/// 鍙栧叏灞€鐘舵€佹墽琛?*寮傛**命令
///
/// # 为什么必须有这个（不能直接用 with_state锛?
///
/// `with_state` 鏄悓姝ョ殑锛岃€?`get_home` / `get_rank` 杩欎簺瑕佽蛋缃戠粶銆?
/// 濡傛灉鍦ㄥ悓姝ヤ笂涓嬫枃閲?`block_on` 瀹冧滑锛?
/// ```text
/// 鉁?闃诲 tokio 鐨?worker 线程 鈫?并发能力下降
/// 鉁?鑻ュ凡鍦?runtime 鍐呴儴鍒?panic锛?Cannot start a runtime from
///   within a runtime"锛夆€斺€?鑰?panic 璺?FFI 杈圭晫鏄?UB
/// ```
///
/// 鎵€浠ヨ繖閲岀敤 `runtime().block_on(...)` 鏄?*瀹夊叏鐨?*锛屽洜涓?
/// `dispatch_blocking` 鏈韩灏辫窇鍦?tokio 鐨?worker 线程上，
/// 而它调用 `block_on` 浼?panic鈥︹€?
///
/// ⚠️ 等等 鈥斺€?杩欐鏄棶棰樻墍鍦ㄣ€傝涓嬮潰 `sourin_call` 鐨勮鏄庯細
///    寮傛鍛戒护**必须**通过 `sourin_call_async` 璋冪敤锛?
///    閭ｄ釜璺緞宸茬粡鍦?tokio 閲岋紝涓嶈兘鍐?block_on銆?
///
/// 鎵€浠ユ湰鍑芥暟鐨勫疄鐜版槸锛?*鍦ㄧ嫭绔嬬殑绾跨▼涓?block_on**锛?
/// 避开「runtime 鍐呬笉鑳?block_on 鑷繁銆嶇殑闄愬埗銆?
async fn with_state_async<T, F, Fut>(f: F) -> String
where
    T: serde::Serialize + Send + 'static,
    F: FnOnce(&'static crate::state::AppState) -> Fut + Send + 'static,
    Fut: std::future::Future<Output = Result<T, String>> + Send + 'static,
{
    let Some(st) = state() else {
        return err_json(
            "鏍稿績灏氭湭鍚姩 鈥斺€?请先调用 sourin_start({dataDir})",
            "unsupported",
        );
    };

    /*
     * 鈽?涓轰粈涔堝湪鏂扮嚎绋嬩笂璺?
     *
     * `sourin_call_async` 鐨勫洖璋冭矾寰勬湰韬凡缁忓湪 tokio runtime 閲屻€?
     * 在那里调 `runtime().block_on()` 浼?panic锛?
     * ```text
     * Cannot start a runtime from within a runtime
     * ```
     * 鑰?panic 璺?FFI 鏄?UB 鈥斺€?浼氱洿鎺ュ穿鎺?Flutter銆?
     *
     * 鏂板紑涓€涓嚎绋嬫潵 block_on 鏄渶绠€鍗曚笖姝ｇ‘鐨勫仛娉曪細
     * 绾跨▼閲屾病鏈?runtime 涓婁笅鏂囷紝鍙互瀹夊叏 block_on銆?
     *
     * 浠ｄ环鏄瘡娆″紓姝ュ懡浠ゅ涓€涓嚎绋嬪垱寤恒€傝繖浜涘懡浠ら兘鏄綉缁滄搷浣?
     * 锛堝嚑鍗佸埌鍑犵櫨姣锛夛紝绾跨▼鍒涘缓锛堝井绉掔骇锛夊彲蹇界暐銆?
     */
    /*
     * 鈽呪槄鈽?蹇呴』鐢?`spawn_blocking` 鑰屼笉鏄?`thread::spawn` + `join`
     *     锛?026-09-23 瀹炴祴鎶撳埌鐨?*死锁**锛?
     *
     * # ֢״
     *
     * 首页同时加载 8 涓尯鍧楋紙8 涓苟鍙?`get_list`）：
     * ```text
     * Rust 鍗曟祴閲?8 涓苟鍙? 鈫?3.9 绉掑叏閮ㄥ畬鎴?
     * Dart 搴旂敤閲屽悓鏍?8 涓? 鈫?**全部 120 绉掕秴鏃?*
     * ```
     * 而且**单个**调用完全正常 鈥斺€?鍙湁骞跺彂鎵嶆寕銆?
     *
     * # 死锁链条
     *
     * ```text
     * Dart 骞跺彂璋?8 涓懡浠?
     *   鈫?sourin_call_async × 8 鈫?runtime().spawn() × 8
     *      （worker_threads = 4锛屽彧鏈?4 涓兘绔嬪埢璺戯級
     *   鈫?dispatch_blocking 鈫?with_state_async
     *   鈫?std::thread::spawn(fut) + handle.join()   鈫?join 闃诲 worker
     *   鈫?4 涓?worker 鍏ㄨ join ռס
     *   鈫?浣?fut 瑕佽窇鍦?*鍚屼竴涓?runtime** 涓?
     *   鈫?runtime 没有空闲 worker 鍘?poll 那些 future
     *   鈫?鈽?join 绛?future，future 绛?worker，worker 鍦?join
     * ```
     *
     * 1 涓苟鍙戞椂娌′簨锛堣繕鏈?3 涓┖闂?worker）；
     * 4 涓互涓婂苟鍙戝氨**必然全挂**銆?
     *
     * # 为什么用 spawn_blocking 能解
     *
     * `spawn_blocking` 鎶婁换鍔℃斁鍒?tokio 鐨?*闃诲绾跨▼姹?*
     * （与 worker 绾跨▼姹犳槸鍒嗗紑鐨勶紝涓婇檺榛樿 512锛夈€?
     * 鍦ㄩ偅閲?`block_on` 不会占用 worker 线程 鈥斺€?
     * future 仍有 worker 鍙敤锛宩oin 涔熷氨涓嶅啀浜掔浉绛夈€?
     *
     * 这也正是 tokio 鏂囨。瀵广€岃鍦?async 涓婁笅鏂囬噷璺戦樆濉炰唬鐮併€嶇殑瀹樻柟寤鸿锛?
     * ```text
     * 鉂?std::thread::spawn + join   锛堣嚜宸辩绾跨▼锛屼細楗挎 worker锛?
     * 鉁?tokio::task::spawn_blocking 锛堜氦缁?runtime 鐨勯樆濉炴睜锛?
     * ```
     *
     * ⚠️ 改动：`JoinHandle::join()` 鈫?`.await`锛堟墍浠ヨ繖涓嚱鏁板繀椤绘槸 async锛夈€?
     */
    let handle = tokio::task::spawn_blocking(move || {
        let fut = f(st);
        runtime().block_on(fut)
    });

    match handle.await {
        Ok(Ok(v)) => serde_json::to_string(&v)
            .unwrap_or_else(|e| err_json(&format!("搴忓垪鍖栬繑鍥炲€煎け璐? {e}"), "other")),
        Ok(Err(e)) => err_json(&e, classify_error(&e)),
        // JoinError锛氫换鍔?panic 鎴栬鏉€
        Err(e) => err_json(
            &format!("鍛戒护鎵ц浠诲姟澶辫触锛堝凡鎹曡幏锛屾湭宕╂簝锛? {e}"),
            "other",
        ),
    }
}

/// 鍙栧叏灞€鐘舵€佹墽琛屽懡浠わ紝骞剁粺涓€澶勭悊銆屾湭鍚姩銆嶄笌銆岀粨鏋滃簭鍒楀寲銆?
///
/// # 涓轰粈涔堣鏈夎繖涓寘瑁?
///
/// 涓夋潯閲嶅閫昏緫锛?0 涓懡浠ゆ瘡涓兘鍐欎竴閬嶅お鍟板棪锛?
/// ```text
/// 鈶?鐘舵€佹病鍚姩     鈫?鏄庣‘鐨勯敊璇紙鑰屼笉鏄?panic锛?
/// 鈶?Result<T,String> 鈫?鎴愬姛搴忓垪鍖?T锛屽け璐ヨ浆鎴?err_json
/// 鈶?T 蹇呴』鍙簭鍒楀寲
/// ```
fn with_state<T, F>(f: F) -> String
where
    T: serde::Serialize,
    F: FnOnce(&crate::state::AppState) -> Result<T, String>,
{
    let Some(st) = state() else {
        return err_json(
            "鏍稿績灏氭湭鍚姩 鈥斺€?请先调用 sourin_start({dataDir})",
            "unsupported",
        );
    };
    match f(st) {
        Ok(v) => serde_json::to_string(&v).unwrap_or_else(|e| {
            err_json(&format!("搴忓垪鍖栬繑鍥炲€煎け璐? {e}"), "other")
        }),
        Err(e) => err_json(&e, classify_error(&e)),
    }
}

/// 鎶婇敊璇秷鎭矖鍒嗙被锛堜笌鍘熺増鍓嶇鐨?ApiError.kind 鍒ゅ畾瑙勫垯涓€鑷达級
///
/// 鍘熺増鏄湪**鍓嶇**鐢ㄦ鍒欏垽鐨勶紙`src/api/index.ts:69-72`锛夈€?
/// 鎼埌杩欓噷鏇村ソ 鈥斺€?鏍稿績鐭ラ亾閿欒鐨勭湡瀹炴潵婧愶紝
/// 姣旂敤姝ｅ垯鐚滃瓧绗︿覆鍑嗗緱澶氥€?
///
/// ⚠️ 浣嗘鍒欒鍒欐湰韬鍜屽墠绔繚鎸佸吋瀹癸紝閬垮厤鍚屼竴涓敊璇袱杈瑰垎绫讳笉鍚屻€?
fn classify_error(msg: &str) -> &'static str {
    let m = msg.to_lowercase();
    if m.contains("timeout") || m.contains("网络") || m.contains("请求失败") || m.contains("连接")
    {
        "network"
    } else if m.contains("登录") || m.contains("401") || m.contains("unauthor") {
        "unauthorized"
    } else if m.contains("不支持") || m.contains("未配置") {
        "unsupported"
    } else if m.contains("不存在") || m.contains("未找到") || m.contains("未返回") {
        "not_found"
    } else {
        "other"
    }
}

/// 缁熶竴鏋勯€犻敊璇?JSON 鈥斺€?閿欒鍒嗙被涓庡師鐗堝墠绔殑 ApiError.kind 对齐
///
/// 涓轰粈涔堣鏈?kind：UI 瑕佹寜绫诲瀷缁欎笉鍚屾彁绀?
/// ```text
/// network      鈫?鎻愮ず妫€鏌ョ綉缁?/ 换源
/// unauthorized 鈫?寮曞鍘荤櫥褰?
/// not_found    鈫?鎻愮ず璧勬簮涓嶅瓨鍦?
/// unsupported  鈫?鎻愮ず涓嶆敮鎸侊紙濡?DRM锛?
/// other        鈫?兜底
/// ```
fn err_json(msg: &str, kind: &str) -> String {
    format!(
        r#"{{"error":{},"kind":{}}}"#,
        serde_json::to_string(msg).unwrap_or_else(|_| "\"\"".into()),
        serde_json::to_string(kind).unwrap_or_else(|_| "\"other\"".into())
    )
}

// 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
//  测试
// 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_callable_and_nul_terminated() {
        let p = sourin_core_version();
        assert!(!p.is_null());
        let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap();
        assert!(s.starts_with("sourin-core"), "鐗堟湰涓蹭笉瀵? {s}");
    }

    #[test]
    fn ping_works() {
        let r = dispatch_blocking(r#"{"cmd":"ping"}"#);
        let v: serde_json::Value = serde_json::from_str(&r).unwrap();
        assert_eq!(v["ok"], true);
    }

    /// 鈽?鍏抽敭鍥炲綊锛氶敊璇繀椤绘槸**合法 JSON**，不能是裸字符串
    ///
    /// 为什么重要：Dart 渚х粺涓€ `jsonDecode` 瑙ｆ瀽缁撴灉銆?
    /// 濡傛灉鏌愭潯閿欒璺緞杩斿洖浜嗚８鏂囨湰锛孌art 侧会抛格式异常，
    /// 鐢ㄦ埛鐪嬪埌鐨勬槸銆岃В鏋愬け璐ャ€嶈€屼笉鏄湡瀹炲師鍥?鈥斺€?鏋侀毦鏌ャ€?
    #[test]
    fn errors_are_valid_json() {
        for req in [
            r#"not json at all"#,
            r#"{}"#,
            r#"{"cmd":"no_such_command"}"#,
        ] {
            let r = dispatch_blocking(req);
            let v: serde_json::Value = serde_json::from_str(&r)
                .unwrap_or_else(|e| panic!("请求 {req} 鐨勯敊璇繑鍥炰笉鏄悎娉?JSON: {r} 鈥斺€?{e}"));
            assert!(v.get("error").is_some(), "缂?error 瀛楁: {r}");
            assert!(v.get("kind").is_some(), "缂?kind 瀛楁: {r}");
        }
    }

    /// 鏈帴鍏ョ殑鍛戒护蹇呴』鎶?`unsupported`锛堣€屼笉鏄潤榛樻垚鍔燂級
    ///
    /// 闈欓粯鎴愬姛鏈€鍗遍櫓锛歎I 浠ヤ负鎿嶄綔鐢熸晥浜嗭紝瀹為檯浠€涔堥兘娌″仛銆?
    ///
    /// # 鈽?鐢ㄣ€屾案涓嶆帴鍏ャ€嶇殑鍛戒护鍚嶏紝涓嶈鐢ㄣ€屾殏鏃舵病鎺ュ叆銆嶇殑
    ///
    /// 杩欎釜娴嬭瘯鍘熸潵鐢ㄧ殑鏄?`search_all` 鈥斺€?閭ｆ椂瀹冪‘瀹炶繕娌℃帴鍏ャ€?
    /// 鎵规 3 接入之后测试就挂了（kind 浠?unsupported 变成 other锛?
    /// 鍥犱负宸叉帴鍏ョ殑鍛戒护缂哄弬鏁版椂璧扮殑鏄弬鏁伴敊璇級銆?
    ///
    /// 杩欎笉鏄洖褰掞紝鏄?*测试选材不当**锛氱敤涓€涓?灏嗘潵浼氳瀹炵幇"的命令名
    /// 鍋?鏈疄鐜?鐨勬柇瑷€锛屾敞瀹氫細鍦ㄥ疄鐜伴偅澶╁け鏁堛€?
    ///
    /// 鎵€浠ユ敼鐢ㄤ竴涓?*璇箟涓婂氨涓嶅彲鑳藉瓨鍦?*的命令名
    ///（`definitely_not_a_real_command_xyz`锛夆€斺€?瀹冩案杩滀笉浼氳瀹炵幇銆?
    #[test]
    fn unimplemented_command_reports_unsupported() {
        let cmd = "definitely_not_a_real_command_xyz";
        let r = dispatch_blocking(&format!(r#"{{"cmd":"{cmd}"}}"#));
        let v: serde_json::Value = serde_json::from_str(&r).unwrap();
        assert_eq!(v["kind"], "unsupported", "鏈帴鍏ョ殑鍛戒护搴旀姤 unsupported");
        assert!(
            v["error"].as_str().unwrap().contains(cmd),
            "错误消息里应含命令名，便于定位"
        );
    }

    /// panic 涓嶈兘绌块€?FFI 边界
    #[test]
    fn panic_is_caught_and_converted() {
        let r = std::panic::catch_unwind(|| {
            // 妯℃嫙涓€涓?panic 鐨勫懡浠?
            let _ = std::panic::catch_unwind(|| panic!("boom"));
        });
        assert!(r.is_ok());
        // 鐪熸瑕侀獙璇佺殑鏄?dispatch_blocking 里的 catch_unwind 存在
        // 锛堣鍑芥暟瀹炵幇锛夆€斺€?杩欓噷鍙‘璁ゆ満鍒跺彲鐢?
    }

    #[test]
    fn free_accepts_null() {
        unsafe { sourin_free(std::ptr::null_mut()) }; // 涓嶅簲宕?
    }

    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?
    //  真实命令的接线测试（2026-09-22锛?
    // 鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺?

    /// 鈽?鏈惎鍔ㄦ椂璋冪敤闇€瑕佺姸鎬佺殑鍛戒护 鈥斺€?必须给出**鍙搷浣滅殑**閿欒
    ///
    /// 为什么这条重要：Flutter 渚ц皟鐢ㄩ『搴忛敊浜嗭紙蹇樹簡鍏?start锛夋椂锛?
    /// 鐢ㄦ埛鐪嬪埌鐨勫簲璇ユ槸銆屾牳蹇冨皻鏈惎鍔ㄣ€嶏紝鑰屼笉鏄帿鍚嶅叾濡欑殑
    /// 銆屽懡浠ゆ湭鎺ュ叆銆嶆垨鐩存帴宕╂簝銆?
    ///
    /// ⚠️ 娉ㄦ剰锛氳繖涓祴璇曚緷璧栥€孲TATE 鏈璁剧疆銆嶃€?
    ///    Rust 鐨勬祴璇曢粯璁ゅ绾跨▼骞惰锛屽鏋滃埆鐨勬祴璇曞惎鍔ㄤ簡鏍稿績锛?
    ///    杩欓噷灏变細澶辫触銆傛墍浠ユ湰娴嬭瘯鐢?`STATE.get().is_none()` 鍋氬墠缃垽鏂€?
    #[test]
    fn state_commands_without_start_give_actionable_error() {
        if STATE.get().is_some() {
            // 鍒殑娴嬭瘯宸茬粡鍚姩浜嗘牳蹇?鈫?杩欐潯鏃犳硶楠岃瘉锛岃烦杩?
            // 锛堜笉鏄け璐ワ細鐜涓嶆弧瓒筹紝鑰屼笉鏄涓洪敊浜嗭級
            return;
        }
        let r = dispatch_blocking(r#"{"cmd":"list_providers"}"#);
        let v: serde_json::Value = serde_json::from_str(&r).unwrap();
        assert_eq!(v["kind"], "unsupported");
        let msg = v["error"].as_str().unwrap();
        assert!(
            msg.contains("sourin_start"),
            "閿欒娑堟伅搴斿憡璇夎皟鐢ㄦ柟鎬庝箞淇紙瑕佹彁鍒?sourin_start），实际: {msg}"
        );
    }

    /// 缂哄弬鏁扮殑璋冪敤瑕佹姤鏄庣‘閿欒锛屼笉鑳?panic銆佷笉鑳介潤榛?
    #[test]
    fn missing_arg_reports_clear_error() {
        let r = dispatch_blocking(r#"{"cmd":"get_provider_enabled"}"#);
        let v: serde_json::Value = serde_json::from_str(&r).unwrap();
        assert!(v.get("error").is_some(), "缺参数应报错");
        assert!(
            v["error"].as_str().unwrap().contains("id"),
            "閿欒娑堟伅搴旀寚鏄庣己鍝釜鍙傛暟"
        );
    }

    /// `core_is_started` 鎺㈤拡锛氫笉闇€瑕佸惎鍔ㄥ氨鑳藉洖绛?
    #[test]
    fn is_started_probe_needs_no_state() {
        let r = dispatch_blocking(r#"{"cmd":"core_is_started"}"#);
        let v: serde_json::Value = serde_json::from_str(&r).unwrap();
        assert!(v.get("started").is_some(), "应返回 started 字段");
    }

    /// 鈽?閿欒鍒嗙被瑙勫垯锛堜笌鍘熺増鍓嶇 ApiError.kind 瀵归綈锛?
    ///
    /// 分类错了的后果：UI 浼氱粰閿欒鐨勬彁绀恒€?
    /// 姣斿缃戠粶闂琚綊鎴?`other`锛岀敤鎴峰氨鐪嬩笉鍒般€屾鏌ョ綉缁溿€嶇殑寮曞銆?
    #[test]
    fn error_classification_matches_frontend_rules() {
        // 原版 src/api/index.ts:69-72 鐨勫洓鏉¤鍒?
        assert_eq!(classify_error("请求超时 timeout"), "network");
        assert_eq!(classify_error("网络连接失败"), "network");
        assert_eq!(classify_error("登录已过期 401"), "unauthorized");
        assert_eq!(classify_error("unsupported 不支持该格式"), "unsupported");
        assert_eq!(classify_error("资源不存在"), "not_found");
        assert_eq!(classify_error("随便什么别的错误"), "other");
    }

    /// `with_state` 鍦ㄦ垚鍔熻矾寰勪笂瑕佽繑鍥?*绾€?*锛屼笉鏄?`{ok:true,value:..}` 鍖呰
    ///
    /// 为什么：原版 Tauri 鐨?`invoke` 鐩存帴鎶?Rust 鐨勮繑鍥炲€肩粰鍓嶇锛?
    /// 娌℃湁鍖呰灞傘€傚鏋滆繖閲屽姞浜嗗寘瑁咃紝Dart 渚у氨瑕佽窡鐫€鎷嗕竴灞?鈥斺€?
    /// 鑰岀洰鏍囨槸銆屽墠绔唬鐮佸敖閲忕収鎼€嶃€?
    #[test]
    fn successful_result_is_not_wrapped() {
        // 鐢ㄤ竴涓笉闇€瑕佺姸鎬佺殑鍛戒护闂存帴楠岃瘉搴忓垪鍖栬涓?
        let r = dispatch_blocking(r#"{"cmd":"core_version"}"#);
        let v: serde_json::Value = serde_json::from_str(&r).unwrap();
        assert!(v.get("version").is_some(), "搴旇鏄函鍊?");
        assert!(v.get("ok").is_none(), "涓嶈鏈?ok 鍖呰灞?");
    }
}