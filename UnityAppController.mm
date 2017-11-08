#import "UnityAppController.h"
#import "UnityAppController+ViewHandling.h"
#import "UnityAppController+Rendering.h"
#import "iPhone_Sensors.h"

#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CADisplayLink.h>
#import <Availability.h>

#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLDrawable.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>

#include <mach/mach_time.h>

// MSAA_DEFAULT_SAMPLE_COUNT was moved to iPhone_GlesSupport.h
// ENABLE_INTERNAL_PROFILER and related defines were moved to iPhone_Profiler.h
// kFPS define for removed: you can use Application.targetFrameRate (30 fps by default)
// DisplayLink is the only run loop mode now - all others were removed

#include "CrashReporter.h"

#include "UI/OrientationSupport.h"
#include "UI/UnityView.h"
#include "UI/Keyboard.h"
#include "UI/SplashScreen.h"
#include "Unity/InternalProfiler.h"
#include "Unity/DisplayManager.h"
#include "Unity/EAGLContextHelper.h"
#include "Unity/GlesHelper.h"
#include "PluginBase/AppDelegateListener.h"

// Set this to 1 to force single threaded rendering
#define UNITY_FORCE_DIRECT_RENDERING 0

bool    _ios42orNewer           = false;
bool    _ios43orNewer           = false;
bool    _ios50orNewer           = false;
bool    _ios60orNewer           = false;
bool    _ios70orNewer           = false;
bool    _ios80orNewer           = false;
bool    _ios81orNewer           = false;
bool    _ios82orNewer           = false;
bool    _ios83orNewer           = false;
bool    _ios90orNewer           = false;
bool    _ios91orNewer           = false;
bool    _ios100orNewer          = false;

// was unity rendering already inited: we should not touch rendering while this is false
bool    _renderingInited        = false;
// was unity inited: we should not touch unity api while this is false
bool    _unityAppReady          = false;
// see if there's a need to do internal player pause/resume handling
//
// Typically the trampoline code should manage this internally, but
// there are use cases, videoplayer, plugin code, etc where the player
// is paused before the internal handling comes relevant. Avoid
// overriding externally managed player pause/resume handling by
// caching the state
bool    _wasPausedExternal      = false;
// should we skip present on next draw: used in corner cases (like rotation) to fill both draw-buffers with some content
bool    _skipPresent            = false;
// was app "resigned active": some operations do not make sense while app is in background
bool    _didResignActive        = false;

// was startUnity scheduled: used to make startup robust in case of locking device
static bool _startUnityScheduled    = false;

bool    _supportsMSAA           = false;


@implementation UnityAppController

@synthesize unityView               = _unityView;
@synthesize unityDisplayLink        = _unityDisplayLink;

@synthesize rootView                = _rootView;
@synthesize rootViewController      = _rootController;
@synthesize mainDisplay             = _mainDisplay;
@synthesize renderDelegate          = _renderDelegate;
@synthesize quitHandler             = _quitHandler;

#if !UNITY_TVOS
@synthesize interfaceOrientation    = _curOrientation;
#endif

- (id)init
{
    if ((self = [super init]))
    {
        // due to clang issues with generating warning for overriding deprecated methods
        // we will simply assert if deprecated methods are present
        // NB: methods table is initied at load (before this call), so it is ok to check for override
        NSAssert(![self respondsToSelector: @selector(createUnityViewImpl)],
            @"createUnityViewImpl is deprecated and will not be called. Override createUnityView"
            );
        NSAssert(![self respondsToSelector: @selector(createViewHierarchyImpl)],
            @"createViewHierarchyImpl is deprecated and will not be called. Override willStartWithViewController"
            );
        NSAssert(![self respondsToSelector: @selector(createViewHierarchy)],
            @"createViewHierarchy is deprecated and will not be implemented. Use createUI"
            );
    }
    return self;
}

- (void)setWindow:(id)object        {}
- (UIWindow*)window                 { return _window; }


- (void)shouldAttachRenderDelegate  {}
- (void)preStartUnity               {}


- (void)startUnity:(UIApplication*)application
{
    NSAssert(_unityAppReady == NO, @"[UnityAppController startUnity:] called after Unity has been initialized");

    UnityInitApplicationGraphics(UNITY_FORCE_DIRECT_RENDERING);

    // we make sure that first level gets correct display list and orientation
    [[DisplayManager Instance] updateDisplayListInUnity];

    UnityLoadApplication();
    Profiler_InitProfiler();

    [self showGameUI];
    [self createDisplayLink];

    UnitySetPlayerFocus(1);
}

extern "C" void UnityDestroyDisplayLink()
{
    [GetAppController() destroyDisplayLink];
}

extern "C" void UnityRequestQuit()
{
    _didResignActive = true;
    if (GetAppController().quitHandler)
        GetAppController().quitHandler();
    else
        exit(0);
}

#if !UNITY_TVOS
- (NSUInteger)application:(UIApplication*)application supportedInterfaceOrientationsForWindow:(UIWindow*)window
{
    // UIInterfaceOrientationMaskAll
    // it is the safest way of doing it:
    // - GameCenter and some other services might have portrait-only variant
    //     and will throw exception if portrait is not supported here
    // - When you change allowed orientations if you end up forbidding current one
    //     exception will be thrown
    // Anyway this is intersected with values provided from UIViewController, so we are good
    return (1 << UIInterfaceOrientationPortrait) | (1 << UIInterfaceOrientationPortraitUpsideDown)
        | (1 << UIInterfaceOrientationLandscapeRight) | (1 << UIInterfaceOrientationLandscapeLeft);
}

#endif

#if !UNITY_TVOS
- (void)application:(UIApplication*)application didReceiveLocalNotification:(UILocalNotification*)notification
{
    AppController_SendNotificationWithArg(kUnityDidReceiveLocalNotification, notification);
    UnitySendLocalNotification(notification);
}

#endif

#if UNITY_USES_REMOTE_NOTIFICATIONS
- (void)application:(UIApplication*)application didReceiveRemoteNotification:(NSDictionary*)userInfo
{
    AppController_SendNotificationWithArg(kUnityDidReceiveRemoteNotification, userInfo);
    UnitySendRemoteNotification(userInfo);
}

- (void)application:(UIApplication*)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData*)deviceToken
{
    AppController_SendNotificationWithArg(kUnityDidRegisterForRemoteNotificationsWithDeviceToken, deviceToken);
    UnitySendDeviceToken(deviceToken);
}

#if !UNITY_TVOS
- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo fetchCompletionHandler:(void (^)(UIBackgroundFetchResult result))handler
{
    AppController_SendNotificationWithArg(kUnityDidReceiveRemoteNotification, userInfo);
    UnitySendRemoteNotification(userInfo);
    if (handler)
    {
        handler(UIBackgroundFetchResultNoData);
    }
}

#endif

- (void)application:(UIApplication*)application didFailToRegisterForRemoteNotificationsWithError:(NSError*)error
{
    AppController_SendNotificationWithArg(kUnityDidFailToRegisterForRemoteNotificationsWithError, error);
    UnitySendRemoteNotificationError(error);
}

#endif

- (BOOL)application:(UIApplication*)application openURL:(NSURL*)url sourceApplication:(NSString*)sourceApplication annotation:(id)annotation
{
    NSMutableArray* keys    = [NSMutableArray arrayWithCapacity: 3];
    NSMutableArray* values  = [NSMutableArray arrayWithCapacity: 3];

    #define ADD_ITEM(item)  do{ if(item) {[keys addObject:@#item]; [values addObject:item];} }while(0)

    ADD_ITEM(url);
    ADD_ITEM(sourceApplication);
    ADD_ITEM(annotation);

    #undef ADD_ITEM

    NSDictionary* notifData = [NSDictionary dictionaryWithObjects: values forKeys: keys];
    AppController_SendNotificationWithArg(kUnityOnOpenURL, notifData);
    return YES;
}

- (BOOL)application:(UIApplication*)application willFinishLaunchingWithOptions:(NSDictionary*)launchOptions
{
    return YES;
}

- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions
{
    ::printf("-> applicationDidFinishLaunching()\n");

    // send notfications
#if !UNITY_TVOS
    if (UILocalNotification* notification = [launchOptions objectForKey: UIApplicationLaunchOptionsLocalNotificationKey])
        UnitySendLocalNotification(notification);

    if ([UIDevice currentDevice].generatesDeviceOrientationNotifications == NO)
        [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
#endif

    UnityInitApplicationNoGraphics([[[NSBundle mainBundle] bundlePath] UTF8String]);

    [self selectRenderingAPI];
    [UnityRenderingView InitializeForAPI: self.renderingAPI];

    _window         = [[UIWindow alloc] initWithFrame: [UIScreen mainScreen].bounds];
    _unityView      = [self createUnityView];

    [DisplayManager Initialize];
    _mainDisplay    = [DisplayManager Instance].mainDisplay;
    [_mainDisplay createWithWindow: _window andView: _unityView];

    [self createUI];
    [self preStartUnity];

    // if you wont use keyboard you may comment it out at save some memory
    [KeyboardDelegate Initialize];

    // 添加右旋按钮
    UIButton *rightBtn = [[UIButton alloc] initWithFrame:CGRectMake(10, 150, 100, 30)];
    rightBtn.backgroundColor = [UIColor whiteColor];
    [rightBtn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [rightBtn setTitle:@"向右旋转" forState:UIControlStateNormal];
    [rightBtn addTarget:self action:@selector(rightBtnClick) forControlEvents:UIControlEventTouchUpInside];
    // 在Unity界面添加按钮
    [UnityGetGLViewController().view addSubview:rightBtn];
    
    UIButton *leftBtn = [[UIButton alloc] initWithFrame:CGRectMake(10, 350, 100, 30)];
    leftBtn.backgroundColor = [UIColor whiteColor];
    [leftBtn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [leftBtn setTitle:@"向左旋转" forState:UIControlStateNormal];
    [leftBtn addTarget:self action:@selector(leftBtnClick) forControlEvents:UIControlEventTouchUpInside];
    // 在Unity界面添加按钮
    [UnityGetGLViewController().view addSubview:leftBtn];
    
    return YES;
}
-(void)rightBtnClick
{
    //通知U3D开始截屏
    UnitySendMessage("Canvas","StartScreenshot","");
    NSString * Path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    
    NSString *  _pathFirst = [NSString stringWithFormat:@"%@/%ld%@",Path,GetAppController().frameCount,@"u3d.JPG"];
    //因为拿到的是个路径 把它加载成一个data对象
    NSData *data0=[NSData dataWithContentsOfFile:_pathFirst];
    //直接把该 图片读出来
    UIImage *img0=[UIImage imageWithData:data0];
    UIImageWriteToSavedPhotosAlbum(img0, GetAppController(), @selector(image:didFinishSavingWithError:contextInfo:), NULL);
//    NSLog(@"开始");
//    //如果还没有开始录制，判断系统是否支持
//    if ([RPScreenRecorder sharedRecorder].available) {
//        NSLog(@"OK");
//        //如果支持，就使用下面的方法可以启动录制回放
//        [[RPScreenRecorder sharedRecorder] startRecordingWithMicrophoneEnabled:YES handler:^(NSError * _Nullable error) {
//            NSLog(@"%@", error);
//            //处理发生的错误，如设用户权限原因无法开始录制等
//        }];
//    } else {
//        NSLog(@"录制回放功能不可用");
//    }
}
-(void)leftBtnClick
{
//    NSLog(@"结束");
//    //停止录制回放，并显示回放的预览，在预览中用户可以选择保存视频到相册中、放弃、或者分享出去
//    [[RPScreenRecorder sharedRecorder] stopRecordingWithHandler:^(RPPreviewViewController * _Nullable previewViewController, NSError * _Nullable error) {
//        if (error) {
//            NSLog(@"%@", error);
//            //处理发生的错误，如磁盘空间不足而停止等
//        }
//        if (previewViewController) {
//            //设置预览页面到代理
//            previewViewController.previewControllerDelegate = self;
//            [GetAppController().window.rootViewController presentViewController:previewViewController animated:YES completion:nil];
//        }
//    }];
}
//回放预览界面的代理方法
- (void)previewControllerDidFinish:(RPPreviewViewController *)previewController {
    //用户操作完成后，返回之前的界面
    [previewController dismissViewControllerAnimated:YES completion:nil];
}
extern "C"
{
    void StartV()
    {

        NSLog(@"开始");
        //如果还没有开始录制，判断系统是否支持
        if ([RPScreenRecorder sharedRecorder].available) {
            NSLog(@"OK");
            //如果支持，就使用下面的方法可以启动录制回放
            [[RPScreenRecorder sharedRecorder] startRecordingWithMicrophoneEnabled:YES handler:^(NSError * _Nullable error) {
                NSLog(@"%@", error);
                //处理发生的错误，如设用户权限原因无法开始录制等
            }];
        } else {
            NSLog(@"录制回放功能不可用");
        }
    }
    void StopV()
    {

        NSLog(@"结束");
        //停止录制回放，并显示回放的预览，在预览中用户可以选择保存视频到相册中、放弃、或者分享出去
        [[RPScreenRecorder sharedRecorder] stopRecordingWithHandler:^(RPPreviewViewController * _Nullable previewViewController, NSError * _Nullable error) {
            if (error) {
                NSLog(@"%@", error);
                //处理发生的错误，如磁盘空间不足而停止等
            }
            if (previewViewController) {
                //设置预览页面到代理
                previewViewController.previewControllerDelegate = GetAppController();
                [GetAppController().window.rootViewController presentViewController:previewViewController animated:YES completion:nil];
            }
        }];
    }
    void SharaV()
    {
        /*
         unity脚本对应方法
         int count = 0;
         //在这里OC的代码通知U3D截屏
         void StartScreenshot(string str)
         {
         Application.CaptureScreenshot(count +"u3d.JPG");
         count++;
         }
         */
        //通知U3D开始截屏
        UnitySendMessage("Canvas","StartScreenshot","");
        NSString * Path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        
        NSString *  _pathFirst = [NSString stringWithFormat:@"%@/%ld%@",Path,GetAppController().frameCount,@"u3d.JPG"];
        //因为拿到的是个路径 把它加载成一个data对象
        NSData *data0=[NSData dataWithContentsOfFile:_pathFirst];
        //直接把该 图片读出来
        UIImage *img0=[UIImage imageWithData:data0];
        UIImageWriteToSavedPhotosAlbum(img0, GetAppController(), @selector(image:didFinishSavingWithError:contextInfo:), NULL);
    }
    void unityToIOS(char* str)
    {
        
    }
}
- (void)image: (UIImage *) image didFinishSavingWithError: (NSError *) error contextInfo: (void *) contextInfo
{
    NSString *msg = nil ;
    
    if(error != NULL){
        
        msg = @"保存图片失败" ;
        
    }else{
        
        msg = @"保存图片成功" ;
        
    }
    
}
- (void)applicationDidEnterBackground:(UIApplication*)application
{
    ::printf("-> applicationDidEnterBackground()\n");
}

- (void)applicationWillEnterForeground:(UIApplication*)application
{
    ::printf("-> applicationWillEnterForeground()\n");

    // applicationWillEnterForeground: might sometimes arrive *before* actually initing unity (e.g. locking on startup)
    if (_unityAppReady)
    {
        // if we were showing video before going to background - the view size may be changed while we are in background
        [GetAppController().unityView recreateGLESSurfaceIfNeeded];
    }
}

- (void)applicationDidBecomeActive:(UIApplication*)application
{
    ::printf("-> applicationDidBecomeActive()\n");

    [self removeSnapshotView];

    if (_unityAppReady)
    {
        if (UnityIsPaused() && _wasPausedExternal == false)
        {
            UnityWillResume();
            UnityPause(0);
        }
        UnitySetPlayerFocus(1);
    }
    else if (!_startUnityScheduled)
    {
        _startUnityScheduled = true;
        [self performSelector: @selector(startUnity:) withObject: application afterDelay: 0];
    }

    _didResignActive = false;
}

- (void)removeSnapshotView
{
    // do this on the main queue async so that if we try to create one
    // and remove in the same frame, this always happens after in the same queue
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_snapshotView)
        {
            [_snapshotView removeFromSuperview];
            _snapshotView = nil;
        }
    });
}

- (void)applicationWillResignActive:(UIApplication*)application
{
    ::printf("-> applicationWillResignActive()\n");

    if (_unityAppReady)
    {
        UnitySetPlayerFocus(0);

        _wasPausedExternal = UnityIsPaused();
        if (_wasPausedExternal == false)
        {
            // do pause unity only if we dont need special background processing
            // otherwise batched player loop can be called to run user scripts
            int bgBehavior = UnityGetAppBackgroundBehavior();
            if (bgBehavior == appbgSuspend || bgBehavior == appbgExit)
            {
                // Force player to do one more frame, so scripts get a chance to render custom screen for minimized app in task manager.
                // NB: UnityWillPause will schedule OnApplicationPause message, which will be sent normally inside repaint (unity player loop)
                // NB: We will actually pause after the loop (when calling UnityPause).
                UnityWillPause();
                [self repaint];
                UnityPause(1);

                // this is done on the next frame so that
                // in the case where unity is paused while going
                // into the background and an input is deactivated
                // we don't mess with the view hierarchy while taking
                // a view snapshot (case 760747).
                dispatch_async(dispatch_get_main_queue(), ^{
                    // if we are active again, we don't need to do this anymore
                    if (!_didResignActive)
                    {
                        return;
                    }

                    _snapshotView = [self createSnapshotView];
                    if (_snapshotView)
                        [_rootView addSubview: _snapshotView];
                });
            }
        }
    }

    _didResignActive = true;
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication*)application
{
    ::printf("WARNING -> applicationDidReceiveMemoryWarning()\n");
    UnityLowMemory();
}

- (void)applicationWillTerminate:(UIApplication*)application
{
    ::printf("-> applicationWillTerminate()\n");

    Profiler_UninitProfiler();
    UnityCleanup();

    extern void SensorsCleanup();
    SensorsCleanup();
}

@end


void AppController_SendNotification(NSString* name)
{
    [[NSNotificationCenter defaultCenter] postNotificationName: name object: GetAppController()];
}

void AppController_SendNotificationWithArg(NSString* name, id arg)
{
    [[NSNotificationCenter defaultCenter] postNotificationName: name object: GetAppController() userInfo: arg];
}

void AppController_SendUnityViewControllerNotification(NSString* name)
{
    [[NSNotificationCenter defaultCenter] postNotificationName: name object: UnityGetGLViewController()];
}

extern "C" UIWindow*            UnityGetMainWindow()        {
    return GetAppController().mainDisplay.window;
}
extern "C" UIViewController*    UnityGetGLViewController()  {
    return GetAppController().rootViewController;
}
extern "C" UIView*              UnityGetGLView()            {
    return GetAppController().unityView;
}
extern "C" ScreenOrientation    UnityCurrentOrientation()   { return GetAppController().unityView.contentOrientation; }


bool LogToNSLogHandler(LogType logType, const char* log, va_list list)
{
    NSLogv([NSString stringWithUTF8String: log], list);
    return true;
}

void UnityInitTrampoline()
{
#if ENABLE_CRASH_REPORT_SUBMISSION
    SubmitCrashReportsAsync();
#endif
    InitCrashHandling();

    NSString* version = [[UIDevice currentDevice] systemVersion];

    // keep native plugin developers happy and keep old bools around
    _ios42orNewer = true;
    _ios43orNewer = true;
    _ios50orNewer = true;
    _ios60orNewer = true;
    _ios70orNewer = [version compare: @"7.0" options: NSNumericSearch] != NSOrderedAscending;
    _ios80orNewer = [version compare: @"8.0" options: NSNumericSearch] != NSOrderedAscending;
    _ios81orNewer = [version compare: @"8.1" options: NSNumericSearch] != NSOrderedAscending;
    _ios82orNewer = [version compare: @"8.2" options: NSNumericSearch] != NSOrderedAscending;
    _ios83orNewer = [version compare: @"8.3" options: NSNumericSearch] != NSOrderedAscending;
    _ios90orNewer = [version compare: @"9.0" options: NSNumericSearch] != NSOrderedAscending;
    _ios91orNewer = [version compare: @"9.1" options: NSNumericSearch] != NSOrderedAscending;
    _ios100orNewer = [version compare: @"10.0" options: NSNumericSearch] != NSOrderedAscending;

    // Try writing to console and if it fails switch to NSLog logging
    ::fprintf(stdout, "\n");
    if (::ftell(stdout) < 0)
        UnitySetLogEntryHandler(LogToNSLogHandler);
}
