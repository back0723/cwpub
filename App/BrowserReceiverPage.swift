import Foundation

/// LAN browser receiver, one page with two decoders.
///
/// - **WebCodecs** (HTTPS secure context): each access unit is decoded as it arrives and drawn to
///   the canvas as soon as it is decoded. When the oldest undecoded frame has waited longer than
///   the performance mode allows, the page drops to the next keyframe and asks the iPhone for one.
///   (A fixed "queue over 2 frames" rule fired constantly on head-unit hardware decoders, which
///   normally hold 3–5 frames, and made HTTPS stutter more than HTTP.) In automatic mode, repeated
///   skips switch this page to MSE for the rest of the browser session. Binary packets: 1 byte (1 = keyframe),
///   8 bytes big-endian arrival time in CarWithin' monotonic µs, then the AVCC/HVCC sample.
/// - **MSE** (HTTP fallback): fMP4 over WebSocket. Binary messages start with one byte:
///   2 = init segment, 1 = keyframe fragment, 0 = dependent fragment. The SourceBuffer is only
///   trimmed up to a keyframe it still holds (removing the only IDR froze H.264), latency is kept
///   down with playbackRate, and stalls or decode errors request a keyframe.
///
/// Touch is sent as the full list of held fingers (`touches`), so pinch and rotate work.
/// Errors and, with `?debug=1`, stats are reported back to the iPhone log.
/// The page reports its pixel size, refresh rate and H.265 support (`display`) so CarWithin can
/// follow the head unit's screen, and `struggling` when playback keeps hitching.
enum BrowserReceiverPage {
    /// Sent with hello/format. An open page from an older app build reloads itself,
    /// because its in-page reconnect would otherwise keep running the old script.
    static let version = "1.9.6-ycarwith"
    static let html = Data(#"""
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<link rel="icon" href="data:,">
<title>Carplay</title>
<style>
:root{color-scheme:dark}*{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#05070b;color:#fff;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif}
main{position:relative;width:100%;height:100%}video,canvas,img#pic{position:absolute;left:0;top:0;right:0;bottom:0;width:100%;height:100%;object-fit:contain;background:#000;pointer-events:none}
/* 车机是 Chromium 53：inset:0 要 Chrome 87 才支持，写了等于没写 → #touch 没有宽高、变成 0×0，
   手指全落在它外面，页面一辈子收不到 touchstart，这就是"车机上完全点不动"的真因。
   一律改成 left/top/right/bottom + width/height。 */
#touch{position:fixed;left:0;top:0;right:0;bottom:0;width:100%;height:100%;z-index:2;touch-action:none;user-select:none;-webkit-user-select:none;-webkit-touch-callout:none}
#startPlayback{position:fixed;z-index:5;top:50%;left:50%;transform:translate(-50%,-50%);background:#0a84ff;font-size:17px;padding:12px 20px}
/* CarMode 那种入口：页面先接入，屏幕上给一个"开始投屏"按钮，点了才发起 CarPlay 会话。 */
#startCard{position:fixed;z-index:6;left:0;top:0;right:0;bottom:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;background:#0d1626;color:#fff;text-align:center;padding:24px}
#startCard h1{margin:0;font-size:34px;font-weight:600}
#startCard p{margin:0;font-size:16px;color:#8b9bb4}
#startCard button{border:0;border-radius:14px;padding:16px 40px;background:#0a84ff;color:#fff;font-size:20px;cursor:pointer}
/* 出画后如果网页拿不到播放权限，就给一条"开启声音"提示；不做全屏遮罩，免得挡住车机上的操作。 */
#soundCard{position:fixed;z-index:7;left:50%;bottom:28px;transform:translateX(-50%);display:flex;flex-direction:row;align-items:center;gap:12px;padding:12px 16px;border-radius:16px;background:rgba(12,18,28,.94);color:#fff;box-shadow:0 10px 30px rgba(0,0,0,.5);max-width:calc(100vw - 40px)}
#soundCard h1{display:none}
#soundCard p{margin:0;font-size:15px;line-height:1.4;color:#c7d2e0}
#soundCard button{border:0;border-radius:12px;padding:10px 18px;background:#0a84ff;color:#fff;font-size:16px;cursor:pointer;white-space:nowrap}
#soundCard .sClose{padding:9px 14px;background:rgba(255,255,255,.14);font-size:14px}
/* 返回键/后退按钮走到最后一步时弹的确认框：取消留着，确认才真的退出投屏界面。 */
#exitCard{position:fixed;z-index:9;left:50%;top:50%;transform:translate(-50%,-50%);min-width:300px;max-width:calc(100vw - 40px);padding:22px 24px;border-radius:18px;background:rgba(16,22,32,.96);color:#fff;text-align:center;box-shadow:0 18px 50px rgba(0,0,0,.65)}
#exitCard p{margin:0 0 6px;font-size:18px;font-weight:600}
#exitCard .exNote{margin:0 0 18px;font-size:14px;font-weight:400;color:#9aa7b8}
#exitCard .exRow{display:flex;gap:12px;justify-content:center}
#exitCancel{border:0;border-radius:12px;padding:11px 26px;font-size:16px;cursor:pointer;background:rgba(255,255,255,.16);color:#fff}
#exitConfirm{border:0;border-radius:12px;padding:11px 26px;font-size:16px;cursor:pointer;background:#0a84ff;color:#fff}
.exited main,.exited #top,.exited #stats,.exited #touch,.exited #soundCard{display:none}
#exitedNote{position:fixed;z-index:10;left:0;right:0;top:50%;transform:translateY(-50%);text-align:center;color:#8b9bb4;font-size:16px;display:none}
#exitedRefresh{display:block;margin:18px auto 0;border:0;border-radius:12px;padding:12px 34px;font-size:17px;cursor:pointer;background:#0a84ff;color:#fff}
.exited #exitedNote{display:block}
/* CarMode 的右上角"菜单"：点开是一个白色二级面板（进入全屏 / 在车机播放声音 / 画面适应 / 断开本浏览器）。 */
/* 起始页的"菜单"：文字蓝色、按钮和边框全透明，位置比原来下移 2cm（CSS 1cm = 37.8px，共约 76px）。 */
#menuBtn{position:fixed;z-index:8;right:16px;top:90px;padding:10px 18px;border:0;border-radius:12px;background:none;background-color:transparent;box-shadow:none;color:#0a84ff;font-size:16px;cursor:pointer;backdrop-filter:none;-webkit-backdrop-filter:none}
#menuBtn:active{background:none}
/* max()/env() 在 Chromium 53 也是无效值，会整条声明被丢掉，所以这里只用普通像素值。 */
#menuPanel{position:fixed;z-index:8;right:16px;top:66px;width:320px;max-width:calc(100vw - 32px);padding:18px 22px;border-radius:18px;background:#fff;color:#111;text-align:left;box-shadow:0 16px 48px rgba(0,0,0,.5)}
#menuPanel .miTitle{font-size:14px;color:#8a8a90;margin:0 0 6px}
#menuPanel .mi{display:block;width:100%;text-align:left;border:0;background:none;padding:12px 0;font:inherit;font-size:17px;font-weight:600;color:#111;cursor:pointer}
#menuPanel .miNote{margin:12px 0 0;font-size:13px;line-height:1.55;color:#6b6b70}
/* 起始页（还没投屏时的"浏览器已接入"页）上的"菜单"：只改这颗按钮——
   文字蓝色、底色和边框全透明、整体往下挪 2cm。二级面板完全不动。 */
.onStart #menuBtn{top:calc(14px + 2cm);background:transparent;border:0;color:#0a84ff;backdrop-filter:none;-webkit-backdrop-filter:none;box-shadow:none}
#top{position:fixed;z-index:3;left:16px;right:16px;top:14px;display:flex;justify-content:space-between;align-items:flex-start;gap:10px;pointer-events:none}
.badge{padding:9px 13px;border-radius:14px;background:rgba(18,24,36,.82);backdrop-filter:blur(16px);-webkit-backdrop-filter:blur(16px);font-size:14px}.dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:#ff9f0a;margin-right:8px}.ok .dot{background:#30d158}.bad .dot{background:#ff453a}
.toolbar{display:flex;flex-direction:column;align-items:flex-end;gap:8px}.actions{display:flex;gap:8px;align-items:center;justify-content:flex-end;flex-wrap:wrap}.actions>*{white-space:nowrap}button,a.chip{pointer-events:auto;border:0;border-radius:13px;padding:9px 13px;background:rgba(18,24,36,.82);color:#fff;font:inherit;font-size:14px;backdrop-filter:blur(16px);-webkit-backdrop-filter:blur(16px);cursor:pointer;text-decoration:none}
#stats{position:fixed;z-index:3;left:16px;top:60px;font:12px/1.5 ui-monospace,Menlo,monospace;color:#d1d1d6;white-space:pre}
.tp{position:fixed;z-index:4;width:44px;height:44px;margin:-22px 0 0 -22px;border-radius:50%;border:3px solid rgba(255,255,255,.9);background:rgba(10,132,255,.35);pointer-events:none}
#status,#fast,#statsButton,#full{transition:opacity .3s,visibility .3s}
.idle #top:not(:focus-within) :is(#status,#fast,#statsButton,#full){opacity:0;visibility:hidden}
/* 车机是 Chromium 53，没有 :focus-within，上面那条规则整条失效 → "CarPlay 1436×640…"一直挂着。
   补一条只依赖 .idle 的规则，动画结束状态由 wake() 控制。 */
.idle #status{opacity:0;visibility:hidden}
.fullscreen :is(#status,.actions,#stats,#startPlayback){display:none}
.fullscreen #top{justify-content:flex-end}
[hidden]{display:none!important}
</style>
</head>
<body><main><video id="video" muted autoplay playsinline disablepictureinpicture disableremoteplayback></video><canvas id="view" hidden></canvas><img id="pic" alt="" hidden><canvas id="hold" hidden></canvas><div id="touch"></div></main>
<div id="top"><div id="status" class="badge"><span class="dot"></span><span>正在连接 Carplay…</span></div><div class="toolbar">
  <button id="menuBtn" hidden>菜单</button>
  <div id="menuPanel" hidden>
    <p class="miTitle">浏览器已接入</p>
    <button class="mi" id="miFull">进入全屏</button>
    <button class="mi" id="miRefit">按新尺寸重新适配</button>
    <p class="miNote">将按当前窗口比例重新连接 CarPlay。</p>
    <button class="mi" id="miAudio">在车机播放声音</button>
    <button class="mi" id="miFit">画面适应 · 保持比例</button>
    <button class="mi" id="miDisconnect">断开本浏览器</button>
    <p class="miNote">点击开启网页声音。要改用手机扬声器，请在 iPhone 控制中心选择 iPhone。</p>
  </div>
</div></div>
<div id="stats" class="badge" hidden></div>
<div id="startCard" hidden><h1>浏览器已接入</h1><p>可在手机或浏览器开始连接。</p><button id="startBtn">开始投屏</button></div>
<div id="soundCard" hidden><h1>声音还没开</h1><p>点“开启声音”，CarPlay 的声音就从车机喇叭播放。</p><button id="soundBtn">开启声音</button><button id="soundClose" class="sClose">暂不</button></div>
<button id="startPlayback" hidden>开始播放</button>
<div id="exitCard" hidden><p>退出投屏？</p><p class="exNote">确认后断开画面和声音，退出投屏界面。</p><div class="exRow"><button id="exitCancel">取消</button><button id="exitConfirm">确认</button></div></div>
<div id="exitedNote"><span>已退出投屏，刷新页面可重新连接</span><button id="exitedRefresh">刷新页面</button></div>
<script>
/* This early check uses ES5 so even a restricted WebView can explain why playback cannot start. */
(function () {
  var label = document.getElementById('status').getElementsByTagName('span')[1];
  window.setTimeout(function () {
    if (!window.carWithinPlayerBooted) {
      label.textContent = '播放器未能启动。请更新车机浏览器或 Android System WebView，再打开本页。';
      document.getElementById('status').className = 'badge bad';
    }
  }, 1500);
}());
</script>
<script>
'use strict';
const PAGE_VERSION='\#(version)';
const connectionProtocol=location.protocol==='https:'?'HTTPS':'HTTP';
const $=s=>document.querySelector(s);
const video=$('#video'),view=$('#view'),pic=$('#pic'),hold=$('#hold'),touchLayer=$('#touch'),statusEl=$('#status'),label=statusEl.querySelector('span:last-child'),statsEl=$('#stats'),fastLink=$('#fast');
const MS=(/iPhone|iPad|iPod/.test(navigator.userAgent)&&window.ManagedMediaSource)||window.MediaSource||window.ManagedMediaSource;
const managedMSE=!!MS&&MS===window.ManagedMediaSource;
const startPlayback=$('#startPlayback'),enableAudio=$('#enableAudio');const startCard=$('#startCard'),startBtn=$('#startBtn');
const soundCard=$('#soundCard'),soundBtn=$('#soundBtn'),soundClose=$('#soundClose');
let soundDismissed=false;
function hideSoundCard(){if(soundCard)soundCard.hidden=true;soundDismissed=true}
// 页面接入但还没画面时给出"开始投屏"，由车机这边发起 CarPlay 会话（和 CarMode 一致）。
function showStartCard(){if(startCard&&!shown)startCard.hidden=false;document.body.classList.add('onStart');showMenu()}
function hideStartCard(){if(startCard)startCard.hidden=true;document.body.classList.remove('onStart')}
// 菜单按钮：页面一接上就出现（CarMode 那样，待机页也能点开）。
const menuBtn=$('#menuBtn'),menuPanel=$('#menuPanel');
function showMenu(){if(menuBtn)menuBtn.hidden=false}
let manualStop=false,fitFill=preference('localStorage','carwithin.fit')==='fill';
function applyFit(){
 const v=fitFill?'fill':'contain';
 if(video)video.style.objectFit=v;
 if(view)view.style.objectFit=v;
 const item=$('#miFit');
 if(item)item.textContent=fitFill?'画面适应 · 铺满屏幕':'画面适应 · 保持比例';
}
applyFit();
if(menuBtn){
 menuBtn.onclick=function(e){e.stopPropagation();menuPanel.hidden=!menuPanel.hidden};
 document.addEventListener('click',function(e){
  if(!menuPanel.hidden&&!menuPanel.contains(e.target)&&e.target!==menuBtn)menuPanel.hidden=true;
 });
 $('#miFull').onclick=function(){
  menuPanel.hidden=true;
  toggleFullscreen();
 };
 $('#miAudio').onclick=function(){
  menuPanel.hidden=true;
  if(audioPlaying()){
   // 再点一次就关掉：挂起 AudioContext，顺便让 iPhone 停止送音频。
   soundDismissed=true;
   try{audioContext.suspend()}catch(e){}
   audioStateChanged();
  }else{
   soundDismissed=false;ensureAudioPlayback(true);
  }
 };
 $('#miRefit').onclick=function(){
  menuPanel.hidden=true;setStatus('正在按当前窗口尺寸重新连接 CarPlay…');
  sendDisplay();send({type:'refit'});
 };
 $('#miFit').onclick=function(){menuPanel.hidden=true;fitFill=!fitFill;applyFit();preference('localStorage','carwithin.fit',fitFill?'fill':'contain')};
 $('#miDisconnect').onclick=function(){
  menuPanel.hidden=true;manualStop=true;clearTimeout(retryTimer);retryTimer=0;
  try{ws.close()}catch(e){}
  shown=false;setStatus('已断开本浏览器，刷新页面可重新连接','bad');
 };
}
if(startBtn){
 startBtn.onclick=function(){
  hideStartCard();setStatus('已请求开始投屏，正在连接 CarPlay…');
  send({type:'startProjection'});
  window.setTimeout(function(){if(!shown)showStartCard()},12000);
 };
}
if(soundBtn){
 // 手势里创建并 resume AudioContext；Chromium 53 在无手势时会一直挂起。
 soundBtn.onclick=function(){ensureAudioPlayback(true)};
}
if(soundClose){
 soundClose.onclick=function(){hideSoundCard()};
}
function preference(storage,key,value){
 try{const store=window[storage];if(value===undefined)return store.getItem(key);store.setItem(key,value)}catch(e){}
 return null
}
const canMSE=!!MS&&typeof MS.isTypeSupported==='function';
const canWebCodecs=window.isSecureContext&&typeof VideoDecoder==='function'&&typeof VideoDecoder.isConfigSupported==='function'&&typeof EncodedVideoChunk==='function';
// JPEG compatibility mode: the iPhone decodes H.264/H.265 to standalone JPEG pictures, so this
// page only needs canvas 2D — no MSE, no IDR keyframe. This is how CarMode 2.5 supports old
// head-unit browsers (Chromium 53). Enable with ?jpeg=1, or automatically when the browser has
// neither WebCodecs nor MediaSource. Auto mode also falls back to JPEG after a first-frame timeout.
// An old head-unit WebView (Chromium/Chrome below ~60) has MSE but cannot reliably start H.264
// without a fresh IDR, which is the classic "missing keyframe" black screen. Start those browsers
// in JPEG mode immediately instead of waiting for a timeout.
const chromeVer=(function(){const m=/Chr(?:ome|omium)\/(\d+)/.exec(navigator.userAgent);return m?parseInt(m[1],10):0})();
const oldBrowser=chromeVer>0&&chromeVer<60;
// Any browser without WebCodecs (Chromium <94, Android 4.x head units) cannot use the low-latency
// path, and its MSE decoder routinely never produces a frame without a fresh IDR. JPEG needs
// neither, so make it the default there; ?mse=1 still forces MSE for troubleshooting.
const noWebCodecs=!canWebCodecs&&!/[?&]mse=1/.test(location.search);
// 实测结论（HK1 车机 / Chrome 53 / Crosswalk 23，1922×858）：老车机走 MSE 硬解必卡死——
// iPhone 不管要多少分辨率都发 H.264 High profile（avc1.640028/64002A），这颗老 MediaCodec
// 解不动：先是「播放停滞」「延迟过高」反复跳关键帧，8 秒左右必定 MEDIA_ERR_DECODE，页面重连黑屏。
// JPEG 兼容画面每帧都是一张完整图，不依赖 IDR、不依赖硬解，就是 CarMode 2.5 的老车机方案，
// 所以 Chromium < 60 的车机浏览器默认直接走 JPEG；?mse=1 仍可强制 MSE 用于排查。
const forcedJPEG=/[?&]jpeg=1/.test(location.search);
const forcedMSE=/[?&]mse=1/.test(location.search);
const rememberedJPEG=preference('sessionStorage','carwithin.jpeg')==='1';
let useJPEG=forcedJPEG||!canMSE||(!forcedMSE&&(rememberedJPEG||oldBrowser));
// ?mse=1 forces the compatibility decoder (troubleshooting).
// Automatic mode remembers, for this browser session, that WebCodecs kept hitching here.
let useWebCodecs=!useJPEG&&canWebCodecs&&!/[?&]mse=1/.test(location.search)&&preference('sessionStorage','carwithin.mse')!=='1';
// Performance modes (set on the iPhone): how long a frame may wait for the decoder before the page
// skips to the next keyframe, and how far MSE may lag before it speeds up or jumps.
const PERF={
 auto:{lagMs:250,queue:12,fast:0.3,faster:0.8,jump:2},
 quality:{lagMs:700,queue:40,fast:0.8,faster:1.6,jump:4},
 speed:{lagMs:100,queue:5,fast:0.15,faster:0.4,jump:1}
};
let perfMode='auto',P=PERF.auto,showTouches=false;
// Hitches: skips to a keyframe or stall recoveries, newest last (ms timestamps).
let hitches=[],lastStruggle=0;
function hitch(reason){
 const now=performance.now();hitches.push(now);hitches=hitches.filter(t=>now-t<30000);
 if(useWebCodecs&&fmt&&perfMode==='auto'&&hitches.filter(t=>now-t<10000).length>=4&&
    tryMSE(fmt,'低延迟播放反复跳帧（'+reason+'）')){
  preference('sessionStorage','carwithin.mse','1');hitches=[];return}
 if(hitches.length>=5&&now-lastStruggle>60000){lastStruggle=now;send({type:'struggling',reason,count:hitches.length,decoder:useWebCodecs?'webcodecs':'mse'})}
}
const debug=/[?&]debug=1/.test(location.search);let debugTick=0,received=0;
let ws=null,fmt=null,shown=false,receiverReady=false,attempt=0,retryTimer=0,firstFrameTimer=0,lastKeyRequest=0,idleTimer=0,bytesIn=0;
// JPEG compatibility rendering, CarMode 2.5 的做法：一条 multipart/x-mixed-replace 连接，
// <img src="/mjpeg"> 由浏览器自己的图像解码线程换图、缩放，页面脚本一帧都不碰。
// 之前每帧在脚本里造 blob、换 src、再"实测 fps 降宽度"，1280 只跑到 1~4 fps，还被连降四档拉糊。
let jpegFrames=0,jpegStartAt=0,jpegTimeouts=0;
pic.onload=function(){
 received++;
 if(!jpegStartAt)jpegStartAt=performance.now();
 jpegFrames++;firstFrame();
};
pic.onerror=function(){
 // 服务端重启、会话重连时这条流会断：两秒后重开，别让画面停在最后一张上。
 if(mjpegTimer)return;
 report('info','MJPEG 画面流断开，2 秒后重开');
 mjpegTimer=setTimeout(function(){mjpegTimer=0;openMJPEG()},2000);
};
// 跟不上的时候服务端只丢帧，分辨率不再被拉低——CarMode 也是这么活的。
let mjpegTimer=0;
function openMJPEG(){
 if(mjpegTimer)return;
 pic.hidden=false;
 pic.src='/mjpeg?t='+Date.now();
}
// Clock sync with CarWithin (µs): offset = server − client, best of the lowest-RTT samples.
let clockOffset=null,bestRtt=Infinity,bestAt=0,latencies=[];
const nowUs=()=>performance.now()*1000;
function setStatus(text,state=''){statusEl.hidden=false;label.textContent=text;statusEl.classList.toggle('ok',state==='ok');statusEl.classList.toggle('bad',state==='bad')}
function send(o){if(ws&&ws.readyState===1)ws.send(JSON.stringify(o))}
function report(type,text){send({type,text:String(text).slice(0,300)})}
// At most one request a second: every forced IDR is ~10× a normal frame, so asking faster than
// the decoder recovers floods it with keyframes. CarWithin itself resends until one arrives.
function askKey(reason){const now=performance.now();if(now-lastKeyRequest<1000)return;lastKeyRequest=now;send({type:'keyframe',reason})}
function wake(){document.body.classList.remove('idle');clearTimeout(idleTimer);idleTimer=setTimeout(()=>{if(shown)document.body.classList.add('idle')},3000)}
function holdFrame(){try{if(!useWebCodecs&&!useJPEG&&video.readyState>=2&&video.videoWidth){hold.width=video.videoWidth;hold.height=video.videoHeight;hold.getContext('2d').drawImage(video,0,0);hold.hidden=false}}catch(e){}}

// ---------- optional CarPlay audio ----------
const AudioContextClass=window.AudioContext||window.webkitAudioContext;
const mseAudioClock=new Map(),activeAudio=new Set(),audioSchedule=new Map();
let audioContext=null,audioOffered=false,audioPackets=[],videoStamp=null,videoStampAt=0;
let audioGestureTimer=0;
let audioRx=0;
// 能不能出声只取决于这台浏览器有没有 Web Audio，不再看服务端那个 browserAudio 标志——
// 那个标志一旦是 false，菜单里"在车机播放声音"就永远点了没反应（用户实测就是这样）。
function audioPlaying(){return !!AudioContextClass&&!!audioContext&&audioContext.state==='running'}
function canStartAudio(){return !!AudioContextClass&&!document.hidden}
let audioDropped=0;
function requestAudio(){if(receiverReady)send({type:'audio',enabled:audioPlaying()})}
function clearAudio(){
 audioPackets=[];audioSchedule.clear();audioDropped=0;videoStamp=null;mseAudioClock.clear();
 for(const source of activeAudio){try{source.stop()}catch(e){}}
 activeAudio.clear();
}
function audioStateChanged(){
 clearTimeout(audioGestureTimer);audioGestureTimer=0;
 requestAudio();
 const want=canStartAudio()&&!audioPlaying();
 if(enableAudio)enableAudio.hidden=!want;
 if(soundCard)soundCard.hidden=!want||soundDismissed;
 const item=$('#miAudio');
 if(item)item.textContent=audioPlaying()?'在车机播放声音 · 已开启':'在车机播放声音';
}
function ensureAudioPlayback(fromGesture){
 if(!AudioContextClass){audioStateChanged();return}
 if(!fromGesture&&!canStartAudio()){audioStateChanged();return}
 try{
  if(!audioContext){
   audioContext=new AudioContextClass();
   audioContext.addEventListener('statechange',audioStateChanged);
  }
  if(!audioPlaying())audioContext.resume().then(audioStateChanged).catch(e=>{
   if(fromGesture)report('error','无法开始伴音：'+e.message);
   audioStateChanged();
  });
  audioStateChanged();
 }catch(e){
  report('error','无法建立伴音播放器：'+e.message);
  audioOffered=false;audioStateChanged();
 }
}
if(enableAudio)enableAudio.onclick=()=>ensureAudioPlayback(true);

// ---------- call uplink: the car's own microphone (browser mode only) ----------
// CarLife mode sends your voice through the re-signed APK's AudioRecord. In pure browser mode
// there is no APK, so the page itself must capture the head unit mic and push 16 kHz mono PCM16
// (first byte 7) over the WebSocket; the phone feeds it into the same uplink encoder.
let micState={stream:null,context:null,source:null,node:null,packets:0,wanted:false,reporting:'',lastTry:0};
function micAPI(){
 if(navigator.mediaDevices&&navigator.mediaDevices.getUserMedia)return c=>navigator.mediaDevices.getUserMedia(c);
 const legacy=navigator.getUserMedia||navigator.webkitGetUserMedia;
 if(legacy)return c=>new Promise((res,rej)=>legacy.call(navigator,c,res,rej));
 return null
}
function sendPCM(buffer){if(ws&&ws.readyState===1){try{ws.send(buffer)}catch(e){}}}
function micDownsample(samples,from,to){
 const ratio=from/to,length=Math.floor(samples.length/ratio);
 if(!(length>0))return null;
 const buffer=new ArrayBuffer(1+length*2),view=new DataView(buffer);
 view.setUint8(0,7);
 for(let i=0;i<length;i++){
  const start=Math.floor(i*ratio),end=Math.min(samples.length,Math.floor((i+1)*ratio));
  let sum=0;
  for(let j=start;j<end;j++)sum+=samples[j];
  const n=end>start?sum/(end-start):0;
  view.setInt16(1+i*2,n<0?n*32768:n*32767,true);
 }
 return buffer
}
function startMic(){
 if(micState.stream||micState.node)return;
 micState.wanted=true;
 if(!AudioContextClass){report('error','车机麦克风不可用：浏览器没有 Web Audio');return}
 const api=micAPI();
 if(!api){report('error','车机麦克风不可用：浏览器没有 getUserMedia');return}
 const now=performance.now();
 if(now-micState.lastTry<1200)return;
 micState.lastTry=now;
 api({audio:{echoCancellation:true,noiseSuppression:true,autoGainControl:true,channelCount:1},video:false}).then(stream=>{
  micState.stream=stream;
  try{
   micState.context=new AudioContextClass();
   micState.source=micState.context.createMediaStreamSource(stream);
   const size=4096;
   micState.node=micState.context.createScriptProcessor?
    micState.context.createScriptProcessor(size,1,1):
    micState.context.createJavaScriptNode(size,1,1);
   const rate=micState.context.sampleRate||48000;
   micState.node.onaudioprocess=e=>{
    if(!ws||ws.readyState!==1)return;
    const pcm=micDownsample(e.inputBuffer.getChannelData(0),rate,16000);
    if(!pcm)return;
    sendPCM(pcm);
    if(micState.packets++===0)report('info','车机麦克风已开始上行（'+rate+' Hz → 16000 Hz）');
   };
   micState.source.connect(micState.node);micState.node.connect(micState.context.destination);
   report('info','车机麦克风已开启（'+rate+' Hz → 16000 Hz 上行）');
  }catch(e){report('error','车机麦克风初始化失败：'+e.message)}
 },err=>{
  const name=(err&&(err.name||err.message))||String(err);
  if(micState.reporting!==name){micState.reporting=name;report('error','车机麦克风被拒绝或不可用：'+name)}
 })
}
function stopMic(){
 micState.wanted=false;micState.packets=0;
 if(micState.node){try{micState.node.disconnect()}catch(e){}micState.node.onaudioprocess=null;micState.node=null}
 if(micState.source){try{micState.source.disconnect()}catch(e){}micState.source=null}
 if(micState.stream){try{micState.stream.getTracks().forEach(t=>t.stop())}catch(e){}micState.stream=null}
 if(micState.context){try{micState.context.close()}catch(e){}micState.context=null}
}
function packetTimestamp(u){
 const time=new DataView(u.buffer,u.byteOffset+1,8);
 return time.getUint32(0)*4294967296+time.getUint32(4);
}
function onAudioPacket(u){
 if(u.length<17||document.hidden)return;
 audioRx++;
 if(!audioPlaying())return;
 audioPackets.push({u,stamp:packetTimestamp(u),arrival:performance.now()/1000});
 if(audioPackets.length>180){audioPackets.shift();audioDropped++}
}
function videoClock(){
 if(useWebCodecs)return videoStamp!==null&&performance.now()-videoStampAt<400?videoStamp:null;
 if(video.paused||!shown||video.readyState<2)return null;
 const index=Math.round(video.currentTime/frameSeconds);
 for(let offset=0;offset<4;offset++){
  const stamp=mseAudioClock.get(index-offset);
  if(stamp!==undefined)return stamp+offset*frameSeconds*1e6;
 }
 return null;
}
// Use video as a starting alignment hint. CarPlay often sends no new picture while its
// dashboard is static, so continuous audio must run on its own RTP/sample clock.
const audioBaseBuffer=0.18,audioMaxTarget=0.42,audioScheduleLimit=0.55,audioBacklogLimit=0.95;
function newAudioStream(rate,channels){
 return {rate,channels,target:audioBaseBuffer,lastAdjustment:0,underruns:0,gaps:0,last:null};
}
function adjustAudioBuffer(state,packet,previous,underrun){
 if(!previous)return;
 const sourceDelta=(packet.stamp-previous.stamp)/1e6;
 const jitter=packet.arrival-previous.arrival-sourceDelta;
 if(sourceDelta>0&&sourceDelta<0.65&&(underrun||jitter>0.06)){
  const extra=underrun?0.05:0.02;
  state.target=Math.min(audioMaxTarget,Math.max(state.target+extra,audioBaseBuffer+Math.min(0.24,Math.max(0,jitter))));
  state.lastAdjustment=packet.arrival;
 }else if(Math.abs(jitter)<0.025&&packet.arrival-state.lastAdjustment>8){
  state.target=Math.max(audioBaseBuffer,state.target-0.015);state.lastAdjustment=packet.arrival;
 }
}
function drainAudio(){
 if(!audioPlaying()||document.hidden)return;
 const clock=videoClock(),current=audioContext.currentTime;
 const pending=audioPackets;audioPackets=[];
 const deferred=new Set(),newest=new Map();
 for(const packet of pending)newest.set(packet.u[14],packet.stamp);
 for(const packet of pending){
  const u=packet.u,wire=new DataView(u.buffer,u.byteOffset,u.byteLength);
  const rate=wire.getUint32(9),channels=u[13],stream=u[14],frames=(u.length-15)/(2*channels);
  if(rate<8000||rate>48000||channels<1||channels>2||!Number.isInteger(frames)||frames<1||frames>4096){audioDropped++;continue}
  if(newest.get(stream)-packet.stamp>audioBacklogLimit*1e6){audioDropped++;continue}
  if(deferred.has(stream)){audioPackets.push(packet);continue}
  const duration=frames/rate;
  let state=audioSchedule.get(stream);
  if(!state){state=newAudioStream(rate,channels);audioSchedule.set(stream,state)}
  const previous=state.last,formatChanged=state.rate!==rate||state.channels!==channels;
  const elapsed=previous?(packet.stamp-previous.stamp)/1e6:0;
  if(previous&&!formatChanged&&elapsed<=0&&elapsed> -0.25){audioDropped++;continue}
  let gap=previous?elapsed-previous.duration:0;
  if(Math.abs(gap)<0.012)gap=0;
  const follows=!!previous&&!formatChanged&&elapsed>0&&gap<0.25;
  // Do not turn a burst of missing packets into a growing queue of silence.
  const continuous=follows?previous.end+Math.min(0.025,Math.max(0,gap)):0;
  const queued=!!previous&&previous.end>current;
  const underrun=follows&&continuous<current+0.004;
  // Defer excess future packets rather than dropping a valid burst just because a
  // frame is too far ahead to submit to Web Audio right now.
  if(continuous>current+audioScheduleLimit||(queued&&previous.end>current+audioScheduleLimit)){
   deferred.add(stream);audioPackets.push(packet);continue;
  }

  adjustAudioBuffer(state,packet,formatChanged?null:previous,underrun);
  if(underrun)state.underruns++;
  if(previous&&!formatChanged&&gap>0)state.gaps++;
  const lead=clock===null?0:(packet.stamp-clock)/1e6;
  const delay=Math.min(audioMaxTarget,Math.max(state.target,lead+0.08));
  const at=follows&&!underrun?continuous:Math.max(current+delay,previous?previous.end:0);
  // Keep the sender and output sample clocks aligned over long playback.
  const speed=Math.max(0.995,Math.min(1.005,1+(at-current-state.target)*0.04));
  const fadeFrames=!follows||underrun||gap>0?Math.min(frames,Math.ceil(rate*0.006)):0;
  const audio=audioContext.createBuffer(channels,frames,rate);
  for(let ch=0;ch<channels;ch++){
   const plane=audio.getChannelData(ch);
   for(let i=0;i<frames;i++){
    const gain=i<fadeFrames?i/fadeFrames:1;
    plane[i]=wire.getInt16(15+2*(i*channels+ch),true)/32768*gain;
   }
  }
  const source=audioContext.createBufferSource();
  source.buffer=audio;source.playbackRate.value=speed;
  source.connect(audioContext.destination);activeAudio.add(source);
  source.onended=()=>{activeAudio.delete(source);source.disconnect()};
  source.start(at);
  state.rate=rate;state.channels=channels;
  state.last={stamp:packet.stamp,arrival:packet.arrival,end:at+duration/speed,duration};
 }
}
function audioStats(){
 if(!audioPlaying())return [];
 const stats=[];
 for(const [id,state] of audioSchedule){
  if(!state.last)continue;
  const queued=Math.max(0,(state.last.end-audioContext.currentTime)*1000).toFixed(0);
  stats.push(`音频 ${id} PCM16 · ${state.rate/1000} kHz / ${state.channels} 声道 · 输出 ${audioContext.sampleRate/1000} kHz`,
   `缓冲 ${queued} / 目标 ${Math.round(state.target*1000)} ms · 欠载 ${state.underruns} · 缺口 ${state.gaps}`);
 }
 if(audioDropped)stats.push(`音频丢弃 ${audioDropped} 包`);
 return stats;
}
setInterval(drainAudio,20);

// ---------- connection ----------
function teardown(){
 clearTimeout(firstFrameTimer);
 if(ws){ws.onopen=ws.onmessage=ws.onclose=ws.onerror=null;try{ws.close()}catch(e){}ws=null}
 fmt=null;shown=false;receiverReady=false;clockOffset=null;bestRtt=Infinity;
 audioOffered=false;clearAudio();audioStateChanged();
 teardownMSE();teardownWC();
}
function restart(reason,notify=true){
 if(retryTimer)return;
 if(manualStop){setStatus('已断开本浏览器，刷新页面可重新连接','bad');return}
 if(notify)report('error',reason);
 holdFrame();teardown();
 // Exponential backoff with ±20% jitter so several viewers do not reconnect in lockstep.
 const delay=Math.min(10000,500*2**attempt)*(0.8+Math.random()*0.4);attempt=Math.min(attempt+1,6);
 setStatus(`${reason}，${(delay/1000).toFixed(1)} 秒后重连…`,'bad');
 retryTimer=setTimeout(()=>{retryTimer=0;boot()},delay);
}
function boot(){
 video.hidden=useWebCodecs||useJPEG;view.hidden=!useWebCodecs;if(!useJPEG)pic.hidden=true;
 window.carWithinPlayerBooted=true;
 if(typeof WebSocket!=='function'){setStatus('此浏览器缺少 WebSocket。请更新车机浏览器或 Android System WebView。','bad');return}
 if(useJPEG){openMJPEG();connect();return}
 if(!useWebCodecs&&!canMSE){setStatus('此浏览器缺少兼容播放器，正在切换 JPEG 模式…','bad');useJPEG=true;boot();return}
 connect();
}
// Keep the same identity across socket reconnects, with a separate identity for each page.
const viewerBytes=new Uint8Array(16);
if(window.crypto&&typeof window.crypto.getRandomValues==='function'){window.crypto.getRandomValues(viewerBytes)}
else{for(let i=0;i<16;i++)viewerBytes[i]=Math.floor(Math.random()*256)}
viewerBytes[6]=(viewerBytes[6]&15)|64;viewerBytes[8]=(viewerBytes[8]&63)|128;
const hex2=n=>{const s=n.toString(16);return s.length<2?'0'+s:s};
const viewerHex=Array.from(viewerBytes,b=>hex2(b)).join('');
const viewerID=viewerHex.replace(/^(........)(....)(....)(....)(............)$/,'$1-$2-$3-$4-$5');
function connect(){
 setStatus('正在连接 Carplay…');
 ws=new WebSocket(`${location.protocol==='https:'?'wss':'ws'}://${location.host}/stream`);ws.binaryType='arraybuffer';
 ws.onopen=()=>{
  ping();
  const ready=()=>{
   receiverReady=true;setStatus('已连接，正在等待画面');showMenu();
   // 会话已经在跑（页面马上会收到 format）就不弹"开始投屏"，否则给一个发起入口。
   window.setTimeout(function(){if(!fmt&&!shown)showStartCard()},1200);
   const decoder=useJPEG?'jpeg':useWebCodecs?'webcodecs':'mse';
   send({type:'ready',decoder,viewer:viewerID,audioClock:!!AudioContextClass,picture:useJPEG?'mjpeg':'',ua:(navigator.userAgent||'').slice(0,200)});sendDisplay();requestAudio();if(useJPEG)askKey('JPEG 兼容观看端接入')
  };
  if(useJPEG||useWebCodecs){ready();return}
  setStatus('已连接，正在启动播放器…');bootMSE(ready)
 };
 ws.onmessage=e=>{if(typeof e.data==='string')onText(JSON.parse(e.data));else{const u=new Uint8Array(e.data);if(u[0]===6){return}if(u[0]===3){onAudioPacket(u);return}if(useJPEG)return;received++;useWebCodecs?onPacketWC(u):onBinaryMSE(u)}};
 ws.onclose=()=>restart('连接已断开',false);ws.onerror=()=>{};
}
function onText(m){
 if(m.type==='hello'){
  if(m.page!==PAGE_VERSION){location.reload();return}
  if(PERF[m.perf]){perfMode=m.perf;P=PERF[m.perf]}
  showTouches=!!m.showTouches;audioOffered=!!m.audio;ensureAudioPlayback();
  // Plain HTTP cannot run WebCodecs; offer the HTTPS page when CarWithin serves one.
  if(fastLink&&!canWebCodecs&&location.protocol==='http:'&&m.securePort>0){fastLink.href='/https-setup';fastLink.hidden=false}
  return}
 if(m.type==='pong'){
  if(typeof m.t0!=='number')return;
  const t3=nowUs(),rtt=t3-m.t0;
  if(rtt<=bestRtt*1.5||performance.now()-bestAt>30000){clockOffset=m.s-(m.t0+t3)/2;bestRtt=Math.min(rtt,bestRtt);bestAt=performance.now()}
  return}
 if(m.type==='status'){if(!shown)setStatus(m.text);return}
 if(m.type==='mic'){if(m.on)startMic();else stopMic();return}
 if(m.type!=='format')return;
 if(m.page!==PAGE_VERSION){location.reload();return}
 hideStartCard();
 fmt=m;
 if(m.decoder==='jpeg'){setStatus(`CarPlay ${m.width}×${m.height} · JPEG 兼容 · MJPEG`,'ok');armFirstFrameTimer(m);return}
 if(m.decoder==='webcodecs')configureWC(m);else formatMSE(m);
}
function ping(){if(ws&&ws.readyState===1)send({type:'ping',t0:nowUs()})}
setInterval(ping,1000);
function firstFrame(){
 if(shown)return;shown=true;attempt=0;jpegTimeouts=0;hold.hidden=true;clearTimeout(firstFrameTimer);hideStartCard();
 if(fmt)setStatus(`CarPlay ${fmt.width}×${fmt.height} · ${fmt.fps} · ${fmt.name} · ${connectionProtocol}`,'ok');
 // 按用户要求：出画后不再显示"分辨率 · 帧数 · 编码"那行，整条状态只留给报错用。
 statusEl.hidden=true;wake();
 // JPEG 兼容模式也要试着开声音：能做到就自动出声，做不到就把"开启声音"页推出来。
 ensureAudioPlayback();
}
function tryMSE(m,reason){
 if(!useWebCodecs||!canMSE||!MS.isTypeSupported('video/mp4; codecs="'+m.codec+'"'))return false;
 report('info',reason+'，切换兼容播放器');
 useWebCodecs=false;h265Ok=null;teardown();boot();
 probeH265().then(v=>{h265Ok=v;sendDisplay()});
 return true
}
function armFirstFrameTimer(m){
 clearTimeout(firstFrameTimer);
 const limit=useJPEG?12000:(m.name==='H.265'?5000:8000);
 firstFrameTimer=setTimeout(()=>{
  if(shown)return;
  if(useJPEG){
   jpegTimeouts++;
   report('error',`JPEG 兼容画面首帧超时（第 ${jpegTimeouts} 次）`);
   askKey('JPEG 首帧超时');
   if(jpegTimeouts<3){setStatus('已请求新关键帧，正在等待兼容画面…','bad');armFirstFrameTimer(m);return}
   jpegTimeouts=0;restart('iPhone 未送出画面，正在重试',false);return}
  if(tryMSE(m,'低延迟首帧超时'))return;
  // No picture after 5–8 s: the browser is likely an old head unit that cannot start H.264
  // without a fresh IDR. Fall back to the iPhone-side JPEG stream, which needs no keyframe.
  report('info','首帧超时，切换到 JPEG 兼容画面（无需关键帧）');
  preference('sessionStorage','carwithin.jpeg','1');
  useJPEG=true;useWebCodecs=false;teardown();boot();return
 },limit);
}

// ---------- WebCodecs ----------
let decoder=null,wcConfig=null,wcWaiting=true,wcConfiguring=false,wcPending=[],ctx=null,wcDropped=0,framesDrawn=0,lastDrawAt=0,lastPacketAt=0;
let drawMs=0,drawCount=0,maxQueue=0;
// performance.now() of every chunk handed to the decoder and not yet output, oldest first.
let submitted=[],wcGeneration=0;
function b64(s){return Uint8Array.from(atob(s),c=>c.charCodeAt(0))}
function configureWC(m){
 const config={codec:m.codec,description:b64(m.description),hardwareAcceleration:'prefer-hardware',optimizeForLatency:true};
 teardownWC();const generation=wcGeneration;wcConfiguring=true;armFirstFrameTimer(m);setStatus(`正在解码 ${m.name}…`);
 VideoDecoder.isConfigSupported(config).then(r=>{
  if(generation!==wcGeneration)return;
  if(!r.supported)throw new Error(`不支持 ${m.codec}`);
  report('info',`${navigator.userAgent.slice(0,140)}；WebCodecs ${m.codec} 支持=true`);
  wcConfig=r.config||config;startDecoder();wcConfiguring=false;
  // Start from the newest keyframe that arrived while configuring; older frames are stale.
  let start=-1;wcPending.forEach((u,i)=>{if(u[0]===1)start=i});
  const queued=start<0?[]:wcPending.slice(start);wcPending=[];queued.forEach(onPacketWC);
 }).catch(e=>{
  if(generation!==wcGeneration)return;
  wcConfiguring=false;wcPending=[];
  if(tryMSE(m,'低延迟解码不可用'))return;
  report('error','WebCodecs 不可用：'+e.message);teardown();
  setStatus(m.name==='H.265'?'此浏览器无法播放 H.265。请在 Carplay 改用 H.264 后重启 CarPlay。':'此浏览器无法解码当前 H.264。请试用 720P、30 FPS，或更新车机浏览器。','bad');
  retryTimer=setTimeout(()=>{retryTimer=0;boot()},15000);
 });
}
function startDecoder(){
 ctx=ctx||view.getContext('2d',{alpha:false});
 decoder=new VideoDecoder({
  output(frame){
   submitted.shift();
   // Draw at once: the compositor shows the newest canvas content at each refresh. Waiting for
   // requestAnimationFrame added a frame of latency and Safari throttles it, dropping frames.
   if(document.hidden){frame.close();wcDropped++;return}
   const t=performance.now();draw(frame);drawMs+=performance.now()-t;drawCount++;
  },
  error(e){report('error','WebCodecs 解码错误：'+e.message);recoverWC()}
 });
 decoder.configure(wcConfig);wcWaiting=true;submitted=[];
}
function draw(f){
 if(view.width!==f.displayWidth||view.height!==f.displayHeight){view.width=f.displayWidth;view.height=f.displayHeight}
 ctx.drawImage(f,0,0);videoStamp=f.timestamp;videoStampAt=performance.now();
 if(clockOffset!==null){const l=(nowUs()+clockOffset-f.timestamp)/1000;if(l>-50&&l<5000)latencies.push(l)}
 f.close();framesDrawn++;lastDrawAt=performance.now();firstFrame();
}
function onPacketWC(u){
 if(u.length<10)return;
 if(wcConfiguring){if(wcPending.length<180)wcPending.push(u);return}
 if(!decoder||decoder.state!=='configured')return;
 const key=u[0]===1,ts=packetTimestamp(u),data=u.subarray(9);
 lastPacketAt=performance.now();
 // A hidden page shows nothing: skip decoding and resume at a keyframe when it is visible again.
 if(document.hidden){wcWaiting=true;wcDropped++;return}
 maxQueue=Math.max(maxQueue,decoder.decodeQueueSize);
 if(wcWaiting){if(!key){wcDropped++;askKey('等待关键帧');return}wcWaiting=false}
 // A real backlog means this device decodes slower than it receives: skip to the next keyframe.
 // Judge by how long the oldest frame has waited, not by queue length: hardware decoders on
 // head units normally keep several frames in flight.
 const waited=submitted.length?performance.now()-submitted[0]:0;
 if(!key&&(waited>P.lagMs||submitted.length>P.queue)){wcWaiting=true;wcDropped++;submitted=[];askKey('解码积压');hitch('解码积压');return}
 try{decoder.decode(new EncodedVideoChunk({type:key?'key':'delta',timestamp:ts,data}));submitted.push(performance.now());bytesIn+=data.byteLength}
 catch(e){report('error','提交解码失败：'+e.message);recoverWC()}
}
function recoverWC(){
 if(!wcConfig)return;
 try{if(decoder&&decoder.state!=='closed')decoder.close()}catch(e){}
 startDecoder();askKey('解码器恢复');
}
function teardownWC(){
 wcGeneration++;
 try{if(decoder&&decoder.state!=='closed')decoder.close()}catch(e){}
 decoder=null;wcConfig=null;wcPending=[];wcConfiguring=false;
 // The canvas keeps the last picture while reconnecting.
}
// Packets keep arriving but nothing is drawn: the decoder is wedged.
setInterval(()=>{
 if(!useWebCodecs||!decoder||document.hidden||!shown)return;
 const now=performance.now();
 if(now-lastPacketAt<1000&&now-lastDrawAt>2000){report('info','WebCodecs 无输出，重建解码器');lastDrawAt=now;recoverWC()}
},500);

// ---------- MSE ----------
let media=null,source=null,objectURL='',mediaTag=null,mediaOpenTimer=0,queue=[],keyTimes=[],nextPts=0,frameSeconds=1/60;
let dropUntilKey=false,jumpOnKey=false,pendingJump=null,lastKeyAt=0,stallSince=0,lastTime=-1,lastQuality=null;
function bootMSE(then){
 try{
  const candidate=media=new MS();
  candidate.addEventListener('sourceopen',()=>{
   if(media!==candidate)return;
   clearTimeout(mediaOpenTimer);then()
  },{once:true});
  if(managedMSE){
   video.disableRemotePlayback=true;
   try{video.srcObject=candidate}catch(e){
    objectURL=URL.createObjectURL(candidate);
    mediaTag=document.createElement('source');mediaTag.type='video/mp4';mediaTag.src=objectURL;
    video.appendChild(mediaTag);video.load()
   }
   video.play().catch(e=>{
    if(media===candidate&&e.name==='NotAllowedError'&&video.paused)startPlayback.hidden=false
   });
   mediaOpenTimer=setTimeout(()=>{
    if(media===candidate&&video.paused)startPlayback.hidden=false
   },1500)
  }else{
   mediaOpenTimer=setTimeout(()=>restart('浏览器未能打开视频播放器'),5000);
   objectURL=URL.createObjectURL(candidate);video.src=objectURL
  }
 }catch(e){restart('无法启动视频播放器：'+e.message)}
}
startPlayback.onclick=()=>{
 if(!media||!video.paused)return;
 video.play().catch(e=>{
  if(!media||e.name==='AbortError')return;
  report('error','无法播放：'+e.message);
  setStatus('无法播放，请点「开始播放」重试','bad')
 })
};
function teardownMSE(){
 clearTimeout(mediaOpenTimer);
 startPlayback.hidden=true;
 source=null;queue=[];keyTimes=[];nextPts=0;dropUntilKey=false;jumpOnKey=false;pendingJump=null;stallSince=0;lastTime=-1;
 if(media){try{if(media.readyState==='open')media.endOfStream()}catch(e){}media=null}
 if(video.srcObject)video.srcObject=null;
 if(mediaTag){mediaTag.remove();mediaTag=null}
 if(objectURL){video.removeAttribute('src');try{video.load()}catch(e){}URL.revokeObjectURL(objectURL);objectURL=''}
}
function formatMSE(m){
 const mime=`video/mp4; codecs="${m.codec}"`,ok=MS.isTypeSupported(mime);
 report('info',`${navigator.userAgent.slice(0,140)}；MSE ${m.codec} 支持=${ok}`);
 if(!ok){
  report('error',`不支持 ${mime}`);holdFrame();teardown();
  setStatus(m.name==='H.265'?'此浏览器不支持 H.265。请在 Carplay 改用 H.264 后重启 CarPlay。':'此浏览器不支持当前 H.264。请试用 720P、30 FPS，或更新车机浏览器。','bad');
  // Retry slowly: once the iPhone switches codec this page recovers by itself.
  if(!retryTimer)retryTimer=setTimeout(()=>{retryTimer=0;boot()},15000);return}
 try{source=media.addSourceBuffer(mime)}catch(e){restart('无法创建解码器：'+e.message);return}
 source.mode='sequence';frameSeconds=(m.duration||1500)/(m.timescale||90000);
 source.addEventListener('updateend',afterUpdate);
 source.addEventListener('error',()=>restart('解码缓冲区错误'));
 setStatus(`正在解码 ${m.name}…`);armFirstFrameTimer(m);
}
function onBinaryMSE(u){
 if(u.length<2)return;
 const timed=u[0]===4||u[0]===5;
 if(timed&&u.length<10)return;
 const kind=timed?u[0]-4:u[0],stamp=timed?packetTimestamp(u):null;
 if(dropUntilKey){if(kind===0)return;dropUntilKey=false}
 queue.push({kind,stamp,body:u.subarray(timed?9:1)});pump()}
function trim(force){
 const b=source.buffered;if(!b.length)return false;
 const start=b.start(0),now=video.currentTime;let cut=null;
 // Only cut up to a keyframe that stays in the buffer; everything after it decodes on its own.
 for(const k of keyTimes)if(k<=now-(force?0.05:1))cut=k;
 if(cut===null||cut-start<(force?0.1:4))return false;
 // Half a frame of margin: cut is a float sum and must never land past the IDR's own timestamp.
 source.remove(start,cut-frameSeconds/2);keyTimes=keyTimes.filter(k=>k>=cut);return true;
}
function pump(){
 if(!source||source.updating||!media||media.readyState!=='open')return;
 if(trim(false))return;
 const item=queue.shift();if(!item)return;
 try{
  source.appendBuffer(item.body);bytesIn+=item.body.byteLength;
  if(item.kind===1){keyTimes.push(nextPts);if(keyTimes.length>12)keyTimes.shift();lastKeyAt=performance.now();if(jumpOnKey){pendingJump=nextPts;jumpOnKey=false}}
  if(item.kind!==2){
   if(item.stamp!==null){
    mseAudioClock.set(Math.round(nextPts/frameSeconds),item.stamp);
    if(mseAudioClock.size>2400)mseAudioClock.delete(mseAudioClock.keys().next().value);
   }
   nextPts+=frameSeconds;
  }
 }catch(e){
  if(e.name==='QuotaExceededError'){
   queue.unshift(item);
   // Nothing safe to trim: drop to the next keyframe rather than append frames with missing references.
   if(!trim(true)){const i=queue.findIndex((x,n)=>n>0&&x.kind!==0);queue=i<0?[]:queue.slice(i);if(!queue.length)dropUntilKey=true;askKey('浏览器缓冲区已满');jumpOnKey=true}}
  else restart('写入解码器失败：'+e.message);
 }
}
function afterUpdate(){
 if(pendingJump!==null&&source&&source.buffered.length){const t=pendingJump;pendingJump=null;if(t>video.currentTime+0.1)video.currentTime=t+frameSeconds/2}
 if(video.paused)video.play().catch(e=>{if(managedMSE&&media&&e.name==='NotAllowedError')startPlayback.hidden=false});
 pump();
}
video.addEventListener('loadeddata',firstFrame);
video.addEventListener('playing',()=>{startPlayback.hidden=true;firstFrame();ensureAudioPlayback()});
video.addEventListener('error',()=>{
 if(useWebCodecs||!media)return;
 const e=video.error,codec=fmt?fmt.name:'视频';
 report('error',`${codec} 解码失败（${e?e.code:'?'} ${e&&e.message?e.message:''}）`);
 const hint=codec==='H.265'?'，可换浏览器或在 App 中改用 H.264':'，可换浏览器或调低分辨率和帧率';
 restart(`${codec} 解码失败${hint}`,false);
});
// Latency and stall control, 4 times per second.
setInterval(()=>{
 if(useWebCodecs||!source||!source.buffered.length)return;
 const b=source.buffered,end=b.end(b.length-1),now=video.currentTime,lag=end-now;
 if(now<b.start(0)-0.01){video.currentTime=b.start(0);return}
 const latest=keyTimes.length?keyTimes[keyTimes.length-1]:null;
 if(lag>P.jump){hitch('延迟过高');if(latest!==null&&latest>now+0.5)video.currentTime=latest+frameSeconds/2;else if(!jumpOnKey){jumpOnKey=true;askKey('延迟过高')}}
 video.playbackRate=lag>P.faster?1.5:lag>P.fast?1.15:1;
 // Playhead stuck although newer frames are buffered: the decoder is wedged.
 if(Math.abs(now-lastTime)<0.001&&lag>0.3&&!document.hidden){
  if(!stallSince)stallSince=performance.now();
  const stuck=performance.now()-stallSince;
  if(stuck>1500&&!jumpOnKey){video.play().catch(()=>{});jumpOnKey=true;askKey('播放停滞');hitch('播放停滞')}
  if(stuck>6000){stallSince=0;restart('播放停滞')}
 }else stallSince=0;
 lastTime=now;
 // CarPlay sends one IDR per session: ask for a fresh one now and then so old data can be trimmed.
 if(performance.now()-lastKeyAt>20000&&end-b.start(0)>25){lastKeyAt=performance.now();askKey('定期刷新缓冲')}
},250);

// ---------- stats ----------
let lastStatsAt=performance.now(),lastDrawn=0;let lastJpegFrames=0;
setInterval(()=>{
 const t=performance.now(),dt=(t-lastStatsAt)/1000;lastStatsAt=t;
 if(statsEl.hidden&&!debug){bytesIn=0;latencies=[];return}
 let lines;
 if(useJPEG){
  const fps=(jpegFrames-lastJpegFrames)/dt;lastJpegFrames=jpegFrames;
  lines=[`${connectionProtocol} · JPEG 兼容（绕过关键帧）`,`显示 ${fps.toFixed(0)} fps · 累计 ${jpegFrames} 帧 · RTT ${bestRtt<Infinity?(bestRtt/1000).toFixed(0):'-'} ms`];
 }else if(useWebCodecs){
  const sorted=latencies.slice().sort((a,b)=>a-b),p=q=>sorted.length?sorted[Math.min(sorted.length-1,Math.floor(q*sorted.length))].toFixed(0):'-';
  lines=[`${connectionProtocol} · ${fmt?fmt.name+' '+fmt.codec:'-'} · 性能 ${perfMode}`,`显示 ${((framesDrawn-lastDrawn)/dt).toFixed(0)} fps · 跳过 ${wcDropped} · 解码队列最大 ${maxQueue} · 卡顿 ${hitches.length}/30s`,
   `画面延迟 中位 ${p(0.5)} ms · P95 ${p(0.95)} ms · 绘制 ${drawCount?(drawMs/drawCount).toFixed(1):'-'} ms · RTT ${bestRtt<Infinity?(bestRtt/1000).toFixed(0):'-'} ms`,`码率 ${(bytesIn*8/dt/1e6).toFixed(1)} Mbps`];
  lastDrawn=framesDrawn;wcDropped=0;drawMs=0;drawCount=0;maxQueue=0;
 }else{
  const q=video.getVideoPlaybackQuality?video.getVideoPlaybackQuality():null;
  let fps='-',drop='-';if(q&&lastQuality){fps=((q.totalVideoFrames-lastQuality.totalVideoFrames)/dt).toFixed(0);drop=q.droppedVideoFrames-lastQuality.droppedVideoFrames}lastQuality=q;
  const b=source&&source.buffered.length?source.buffered:null,lag=b?Math.max(0,b.end(b.length-1)-video.currentTime):0,span=b?b.end(b.length-1)-b.start(0):0;
  lines=[`${connectionProtocol} · ${fmt?fmt.name+' '+fmt.codec:'-'} · 性能 ${perfMode}`,`显示 ${fps} fps · 丢帧 ${drop}`,`缓冲延迟 ${(lag*1000).toFixed(0)} ms · 倍速 ${video.playbackRate}`,`码率 ${(bytesIn*8/dt/1e6).toFixed(1)} Mbps · 缓存 ${span.toFixed(1)} s`];
 }
 const audio=audioStats();
 statsEl.textContent=lines.concat(audio).join('\n');bytesIn=0;latencies=[];
 // ?debug=1 mirrors the stats into the iPhone log every 5 s.
 if(debug&&++debugTick%5===0){
  report('info',lines.join(' | ')+` | 收=${received} 隐藏=${document.hidden}`);
  if(audio.length)report('info',audio.join(' | '));
 }
},1000);

// ---------- input ----------
const fingers=new Map();let nextFingerId=0;
function picture(){
 const el=useJPEG?pic:useWebCodecs?view:video,r=el.getBoundingClientRect();
 const vw=(useJPEG?pic.naturalWidth:useWebCodecs?view.width:video.videoWidth)||16,vh=(useJPEG?pic.naturalHeight:useWebCodecs?view.height:video.videoHeight)||9;
 const s=Math.min(r.width/vw,r.height/vh),w=vw*s,h=vh*s;return{x0:r.left+(r.width-w)/2,y0:r.top+(r.height-h)/2,w,h}
}
function sendFingers(){
 const p=picture(),points=[];
 for(const f of fingers.values())points.push({id:f.id,x:Math.max(0,Math.min(1,(f.cx-p.x0)/p.w)),y:Math.max(0,Math.min(1,(f.cy-p.y0)/p.h))});
 send({type:'touches',points});
}
function pressPoint(key,cx,cy){
 if(fingers.size>=10)return;
 const f={id:nextFingerId,cx,cy,dot:null};nextFingerId=(nextFingerId+1)&255;
 if(showTouches){f.dot=document.createElement('div');f.dot.className='tp';document.body.appendChild(f.dot);moveDot(f)}
 fingers.set(key,f);sendFingers();wake();
}
function movePoint(key,cx,cy){const f=fingers.get(key);if(!f)return;f.cx=cx;f.cy=cy;moveDot(f);sendFingers()}
function liftPoint(key){const f=fingers.get(key);if(!f)return;if(f.dot)f.dot.remove();fingers.delete(key);sendFingers()}
// 车机是 Crosswalk 23 / Chromium 53：没有 Pointer Events，而且触摸层在老浏览器上曾经因为没有宽高
// 变成 0×0。这里不再依赖任何图层的尺寸，直接在 document 上抓手指：
// 只要落点不是页面自己的按钮/菜单，就一律转发成 CarPlay 的触摸（CarMode 就是这么点的）。
const CONTROL_SEL='button,#menuBtn,#menuPanel,#soundCard,#startCard,#exitCard,a.chip';
function onControlAt(cx,cy){
 let el=null;
 try{el=document.elementFromPoint(cx,cy)}catch(e){}
 return !!(el&&el.closest&&el.closest(CONTROL_SEL));
}
function bindTouchInput(){
 const changed=e=>Array.prototype.slice.call(e.changedTouches||[]);
 if(window.PointerEvent){
  document.addEventListener('pointerdown',e=>{
   if(!menuPanel.hidden)return;
   if(e.pointerType==='mouse'&&e.button!==0)return;
   if(onControlAt(e.clientX,e.clientY))return;
   pressPoint('p'+e.pointerId,e.clientX,e.clientY);
   if(e.cancelable)e.preventDefault();
  },true);
  document.addEventListener('pointermove',e=>movePoint('p'+e.pointerId,e.clientX,e.clientY),true);
  ['pointerup','pointercancel','lostpointercapture'].forEach(n=>document.addEventListener(n,e=>liftPoint('p'+e.pointerId),true));
  return;
 }
 document.addEventListener('touchstart',e=>{
  if(!menuPanel.hidden)return;
  let onControl=false;
  for(const t of changed(e)){
   if(onControlAt(t.clientX,t.clientY)){onControl=true;continue}
   pressPoint('t'+t.identifier,t.clientX,t.clientY);
  }
  if(!onControl&&e.cancelable)e.preventDefault();
 },{passive:false,capture:true});
 document.addEventListener('touchmove',e=>{
  for(const t of changed(e))movePoint('t'+t.identifier,t.clientX,t.clientY);
 },{passive:false,capture:true});
 ['touchend','touchcancel'].forEach(n=>document.addEventListener(n,e=>{
  for(const t of changed(e))liftPoint('t'+t.identifier);
 },{passive:false,capture:true}));
 // 老浏览器还可能只报鼠标事件（外接鼠标/触控板），再兜一层。
 document.addEventListener('mousedown',e=>{
  if(!menuPanel.hidden||e.button!==0||onControlAt(e.clientX,e.clientY))return;
  pressPoint('m',e.clientX,e.clientY);
 },true);
 document.addEventListener('mousemove',e=>{if(fingers.has('m'))movePoint('m',e.clientX,e.clientY)},true);
 document.addEventListener('mouseup',()=>liftPoint('m'),true);
}
bindTouchInput();
// 通话进行中如果麦克风还没起来（老浏览器要求用户手势里才能申请），车机上一次点按就再试一次。
['pointerdown','touchstart','mousedown'].forEach(n=>document.addEventListener(n,()=>{
 if(micState.wanted&&!micState.stream)startMic();
},true));
function moveDot(f){if(f.dot){f.dot.style.left=f.cx+'px';f.dot.style.top=f.cy+'px'}}
touchLayer.addEventListener('contextmenu',e=>e.preventDefault());
document.addEventListener('mousemove',wake);
document.addEventListener('visibilitychange',()=>{
 if(document.hidden)clearAudio();
 ensureAudioPlayback();
 if(document.hidden&&fingers.size){fingers.forEach(f=>{if(f.dot)f.dot.remove()});fingers.clear();send({type:'touches',points:[]})}
 if(!document.hidden&&useWebCodecs&&decoder){wcWaiting=true;askKey('页面回到前台')}
});
if($('#full'))$('#full').onclick=()=>toggleFullscreen();
function isFullscreen(){return !!(document.fullscreenElement||document.webkitFullscreenElement)}
function pseudoFull(){return document.body.classList.contains('pseudoFull')}
function setPseudoFull(on){document.body.classList.toggle('pseudoFull',on);document.body.classList.toggle('fullscreen',on||isFullscreen())}
function enterFullscreen(){
 armBackGuard();
 const d=document.documentElement;
 try{
  const fn=d.requestFullscreen||d.webkitRequestFullscreen||d.mozRequestFullScreen||d.msRequestFullscreen;
  if(fn)fn.call(d);
 }catch(e){}
 // Crosswalk 23 常常不实现 Fullscreen API（请求了也没反应）。600ms 内没进全屏就退回
 // "整页铺满"模式，至少让菜单里的"退出全屏"和车机返回键都有确定的行为。
 window.setTimeout(function(){if(!isFullscreen()&&!document.hidden)setPseudoFull(true)},600);
}
function exitFullscreenNow(){
 try{
  const fn=document.exitFullscreen||document.webkitExitFullscreen||document.mozCancelFullScreen||document.msExitFullscreen;
  if(fn)fn.call(document);
 }catch(e){}
 if(pseudoFull())setPseudoFull(false);
}
function toggleFullscreen(){
 if(isFullscreen()||pseudoFull())exitFullscreenNow();else enterFullscreen();
}
function fullscreenChanged(){
 const on=isFullscreen()||pseudoFull();
 document.body.classList.toggle('fullscreen',on);
 const item=$('#miFull');if(item)item.textContent=on?'退出全屏':'进入全屏';
 wake();
 // 全屏切换不再上报窗口尺寸：那会让 CarPlay 按新尺寸重连，退出全屏时画面会黑一下。
}
document.addEventListener('fullscreenchange',fullscreenChanged);
document.addEventListener('webkitfullscreenchange',fullscreenChanged);
// 车机的物理返回键 / 浏览器的后退按钮，在网页里都表现为 history 后退。
// 压一个哨兵条目把后退吃掉：全屏时先退全屏；已经到最后一步则弹"确认/取消"，
// 只有点确认才断开投屏并退出界面（取消就继续看）。
let backGuard=false,leaving=false;
function armBackGuard(){if(backGuard)return;backGuard=true;try{history.pushState({cwBack:1},'')}catch(e){}}
function askExit(){const c=$('#exitCard');if(c)c.hidden=false;wake()}
function finishExit(){
 leaving=true;manualStop=true;
 try{ws.close()}catch(e){}
 const c=$('#exitCard');if(c)c.hidden=true;
 if(fingers.size){fingers.forEach(f=>{if(f.dot)f.dot.remove()});fingers.clear()}
 clearAudio();
 document.body.classList.add('exited');
 try{history.replaceState({},'')}catch(e){}
}
window.addEventListener('popstate',function(){
 if(leaving)return;
 if(isFullscreen()||pseudoFull()){
  exitFullscreenNow();
  try{history.pushState({cwBack:1},'')}catch(e){}
  return;
 }
 try{history.pushState({cwBack:1},'')}catch(e){}
 askExit();
});
if($('#exitCancel'))$('#exitCancel').onclick=function(){const c=$('#exitCard');if(c)c.hidden=true};
if($('#exitConfirm'))$('#exitConfirm').onclick=finishExit;
// 退出投屏后给一个"刷新页面"按钮，不用再去点浏览器工具栏的刷新。
if($('#exitedRefresh'))$('#exitedRefresh').onclick=function(){location.reload()};
armBackGuard();
// 用户要求：车机屏幕上不要挂那坨黑色统计（HTTP/JPEG、fps、音频缓冲…）。
// 永久隐藏，同时把之前存在 localStorage 里的开关也清掉，免得升级后又被打开。
statsEl.hidden=true;
statsEl.style.display='none';
try{preference('localStorage','carplays.stats','0')}catch(e){}
if(!canWebCodecs&&location.protocol==='https:')report('info','HTTPS 页面但浏览器没有 WebCodecs，使用 MSE');

// ---------- screen report ----------
// Pixel size, refresh rate and hardware H.265 support, so CarWithin can size CarPlay to this
// screen. Sent on connect and again when the window settles after a resize (fullscreen, split).
let refreshHz=0,h265Ok=null,resizeTimer=0;
function measureRefresh(){
 if(document.hidden)return;let n=0,t0=0;
 const step=t=>{if(!t0)t0=t;n++;if(t-t0<1000){requestAnimationFrame(step);return}
  refreshHz=Math.round((n-1)*1000/(t-t0));sendDisplay()};
 requestAnimationFrame(step);
}
function probeH265(){
 const c='hvc1.1.6.L123.B0';
 const viaMSE=()=>{try{return !!(MS&&MS.isTypeSupported('video/mp4; codecs="'+c+'"'))}catch(e){return false}};
 if(useWebCodecs&&typeof VideoDecoder.isConfigSupported==='function'){
  try{return VideoDecoder.isConfigSupported({codec:c,hardwareAcceleration:'prefer-hardware'}).then(r=>!!(r&&r.supported),viaMSE)}catch(e){}}
 return Promise.resolve(viaMSE())
}
function sendDisplay(){
 if(!receiverReady||!ws||ws.readyState!==1||h265Ok===null)return;
 const dpr=window.devicePixelRatio||1;
 send({type:'display',w:Math.round(innerWidth*dpr),h:Math.round(innerHeight*dpr),dpr,
  sw:Math.round(screen.width*dpr),sh:Math.round(screen.height*dpr),hz:refreshHz,h265:h265Ok,
  fullscreen:isFullscreen(),ua:navigator.userAgent.slice(0,160)});
}
probeH265().then(v=>{h265Ok=v;sendDisplay()});
measureRefresh();
window.addEventListener('resize',()=>{clearTimeout(resizeTimer);resizeTimer=setTimeout(sendDisplay,1500)});
// 老车机上任何一句抛错都会让整页停在"播放器未能启动"。这里把错误抓到状态条上报出来，
// 页面还能继续跑（最多丢一个功能），不再是整页黑屏。
window.addEventListener('error',function(ev){
 try{report('error','页面脚本错误：'+(ev.message||'unknown')+' @'+(ev.lineno||0))}catch(e){}
 setStatus('页面出错：'+(ev.message||'unknown'),'bad');
});
try{boot()}catch(e){setStatus('播放器启动失败：'+(e&&e.message?e.message:e),'bad');report('error','播放器启动失败：'+(e&&e.message?e.message:e))}
</script></body></html>
"""#.utf8)
}
