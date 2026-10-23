#import <Cocoa/Cocoa.h>

#include <map>
#include <limits.h>
#include <string>
#include <vector>
#include "Bridge.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_command_line.h"
#include "include/cef_frame.h"
#include "include/cef_id_mappers.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_browser_view_delegate.h"
#include "include/views/cef_box_layout.h"
#include "include/views/cef_window.h"
#include "include/views/cef_window_delegate.h"

namespace {
class BrowserClient;
std::map<int32_t, CefRefPtr<BrowserClient>> clients;
int32_t next_token = 1;
bool quitting = false;
std::string profile_path;
std::string startup_url;
bool smoke = false;
int smoke_result = 1;
// CEF permits one Chrome-style BrowserView per window on macOS. Inactive tab
// windows stay hidden; the native sidebar model is shared between their shells.
std::map<int32_t, CefRefPtr<CefWindow>> windows;
int32_t active_token = 0;
void MaybeQuit() {
  if (clients.empty() && windows.empty()) CefQuitMessageLoop();
}

class BrowserClient : public CefClient,
                      public CefLifeSpanHandler,
                      public CefDisplayHandler,
                      public CefLoadHandler {
 public:
  explicit BrowserClient(int32_t token) : token_(token) {}
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    browser_ = browser;
    clients[token_] = this;
    if (smoke) fprintf(stdout, "Runtime style=%d (Chrome=%d)\n",
                        browser->GetHost()->GetRuntimeStyle(), CEF_RUNTIME_STYLE_CHROME);
    if (closing_ || quitting) browser->GetHost()->CloseBrowser(true);
  }

  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int popup_id,
                      const CefString &, const CefString &, WindowOpenDisposition,
                      bool, const CefPopupFeatures &, CefWindowInfo &,
                      CefRefPtr<CefClient> &client, CefBrowserSettings &,
                      CefRefPtr<CefDictionaryValue> &, bool *) override {
    // Preserve Chromium's popup/opener behavior (including sign-in windows),
    // with a separate client so a popup never replaces its opener's browser.
    if (quitting) return true;
    int32_t token = next_token++;
    CefRefPtr<BrowserClient> popup = new BrowserClient(token);
    clients[token] = popup;
    pending_popups_[popup_id] = token;
    client = popup;
    return false;
  }
  void OnBeforePopupAborted(CefRefPtr<CefBrowser>, int popup_id) override {
    auto pending = pending_popups_.find(popup_id);
    if (pending != pending_popups_.end()) {
      clients.erase(pending->second);
      pending_popups_.erase(pending);
    }
    if (quitting) MaybeQuit();
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    browser_ = nullptr;
    view_ = nullptr;
    VaneBrowserClosed(token_);
    clients.erase(token_);
    MaybeQuit();
  }

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame, const CefString &url) override {
    if (frame->IsMain()) { url_ = url; Publish(); }
  }
  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString &title) override {
    title_ = title;
    Publish();
    if (smoke && title_.starts_with("VANE_SMOKE_PASS")) {
      fprintf(stdout, "%s\n", title_.c_str());
      fflush(stdout);
      smoke_result = 0;
      // Defer closure until this callback has returned.
      dispatch_async(dispatch_get_main_queue(), ^{ VaneQuit(); });
    }
    if (smoke && title_.starts_with("VANE_SMOKE_FAIL")) {
      fprintf(stderr, "%s\n", title_.c_str());
      dispatch_async(dispatch_get_main_queue(), ^{ VaneQuit(); });
    }
  }
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool loading,
                            bool back, bool forward) override {
    loading_ = loading; back_ = back; forward_ = forward; Publish();
  }
  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                   ErrorCode code, const CefString &text,
                   const CefString &url) override {
    if (frame->IsMain() && code != ERR_ABORTED) {
      title_ = "Couldn’t load page (" + std::to_string(code) + ")";
      if (smoke) fprintf(stderr, "Load error %d: %s\n", code, url.ToString().c_str());
      Publish();
    }
  }

  void Close() {
    closing_ = true;
    if (browser_) {
      browser_->GetHost()->CloseBrowser(true);
    } else {
      auto window = windows.find(token_);
      if (window != windows.end()) window->second->Close();
    }
  }
  CefRefPtr<CefBrowser> browser() const { return browser_; }
  CefRefPtr<CefBrowserView> view() const { return view_; }
  void SetView(CefRefPtr<CefBrowserView> view) { view_ = view; }

 private:
  void Publish() {
    CEF_REQUIRE_UI_THREAD();
    VaneBrowserChanged(token_, url_.c_str(), title_.c_str(), loading_, back_, forward_);
  }
  int32_t token_;
  CefRefPtr<CefBrowser> browser_;
  CefRefPtr<CefBrowserView> view_;
  std::map<int, int32_t> pending_popups_;
  std::string url_, title_;
  bool loading_ = true, back_ = false, forward_ = false, closing_ = false;
  IMPLEMENT_REFCOUNTING(BrowserClient);
};

CefRefPtr<CefBrowser> Browser(int32_t token) {
  CEF_REQUIRE_UI_THREAD();
  const auto found = clients.find(token);
  return found == clients.end() ? nullptr : found->second->browser();
}

class BrowserViewDelegate : public CefBrowserViewDelegate {
 public:
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override { return CEF_CTT_NORMAL; }
 private:
  IMPLEMENT_REFCOUNTING(BrowserViewDelegate);
};

class WindowDelegate : public CefWindowDelegate {
 public:
  WindowDelegate(int32_t token, CefRefPtr<CefBrowserView> view, CefRect bounds)
      : token_(token), view_(view), bounds_(bounds) {}
  void OnWindowCreated(CefRefPtr<CefWindow> window) override {
    windows[token_] = window;
    window->SetTitle("Vane Chromium Prototype");
    window->SetBackgroundColor(0xFF202020);
    CefBoxLayoutSettings layout;
    layout.inside_border_insets = {0, 228, 8, 8};
    layout.cross_axis_alignment = CEF_AXIS_ALIGNMENT_STRETCH;
    layout.default_flex = 1;
    auto box = window->SetToBoxLayout(layout);
    window->AddChildView(view_);
    if (auto toolbar = view_->GetChromeToolbar()) {
      window->AddChildViewAt(toolbar, 0);
      box->SetFlexForView(toolbar, 0);
    }
    window->Layout();
    VaneCreateWindow(window->GetWindowHandle(), token_);
  }
  CefRect GetInitialBounds(CefRefPtr<CefWindow>) override { return bounds_; }
  CefSize GetPreferredSize(CefRefPtr<CefView>) override { return CefSize(1240, 820); }
  CefSize GetMinimumSize(CefRefPtr<CefView>) override { return CefSize(850, 580); }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  bool CanClose(CefRefPtr<CefWindow>) override {
    auto browser = view_ ? view_->GetBrowser() : nullptr;
    return !browser || browser->GetHost()->TryCloseBrowser();
  }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override {
    view_ = nullptr;
    windows.erase(token_);
    VaneWindowClosed(token_);
    // A view can be destroyed before browser creation completed.
    auto client = clients.find(token_);
    if (client != clients.end() && !client->second->browser()) clients.erase(client);
    MaybeQuit();
  }
 private:
  int32_t token_;
  CefRefPtr<CefBrowserView> view_;
  CefRect bounds_;
  IMPLEMENT_REFCOUNTING(WindowDelegate);
};

class PrototypeApp : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  CefRefPtr<CefClient> GetDefaultClient() override {
    // Chrome UI can create windows outside OnBeforePopup (including extension
    // surfaces). Track them once creation succeeds so quit covers them too.
    return new BrowserClient(next_token++);
  }
  void OnContextInitialized() override {
    CEF_REQUIRE_UI_THREAD();
    dispatch_async(dispatch_get_main_queue(), ^{ VaneStart(); });
    if (smoke) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
                     dispatch_get_main_queue(), ^{
        if (!quitting) {
          fprintf(stderr, "FAIL: Chromium smoke test timed out\n");
          VaneQuit();
        }
      });
    }
  }
 private:
  IMPLEMENT_REFCOUNTING(PrototypeApp);
};
}  // namespace

@interface VaneChromiumApplication : NSApplication <CefAppProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@end

@implementation VaneChromiumApplication
- (BOOL)isHandlingSendEvent { return self.handlingSendEvent; }
- (void)sendEvent:(NSEvent *)event {
  CefScopedSendingEvent scope;
  [super sendEvent:event];
}
- (void)terminate:(id)sender { VaneQuit(); }
@end

int32_t VaneCreateBrowser(const char *url) {
  CEF_REQUIRE_UI_THREAD();
  if (quitting) return 0;
  int32_t token = next_token++;
  CefRefPtr<BrowserClient> client = new BrowserClient(token);
  clients[token] = client;
  CefBrowserSettings settings;
  auto view = CefBrowserView::CreateBrowserView(client, url, settings, nullptr, nullptr, new BrowserViewDelegate);
  if (!view) {
    clients.erase(token);
    return 0;
  }
  client->SetView(view);
  CefRect bounds(100, 100, 1240, 820);
  auto active = windows.find(active_token);
  if (active != windows.end()) bounds = active->second->GetBounds();
  CefWindow::CreateTopLevelWindow(new WindowDelegate(token, view, bounds));
  return token;
}
void VaneSelectBrowser(int32_t token) {
  CEF_REQUIRE_UI_THREAD();
  auto next = windows.find(token);
  if (next == windows.end()) return;
  auto previous = windows.find(active_token);
  if (previous != windows.end() && active_token != token) next->second->SetBounds(previous->second->GetBounds());
  active_token = token;
  for (const auto &[id, window] : windows) {
    if (id == token) { window->Show(); window->Activate(); }
    else window->Hide();
  }
}
void VaneNavigate(int32_t token, const char *url) {
  if (auto browser = Browser(token)) browser->GetMainFrame()->LoadURL(url);
}
void VaneGoBack(int32_t token) { if (auto browser = Browser(token)) browser->GoBack(); }
void VaneGoForward(int32_t token) { if (auto browser = Browser(token)) browser->GoForward(); }
void VaneReload(int32_t token) { if (auto browser = Browser(token)) browser->Reload(); }
void VaneFocusAddress(int32_t token) {
  if (auto browser = Browser(token)) {
    browser->GetHost()->ExecuteChromeCommand(cef_id_for_command_id_name("IDC_FOCUS_LOCATION"), CEF_WOD_CURRENT_TAB);
  }
}
void VaneCloseBrowser(int32_t token) {
  auto found = clients.find(token);
  if (found != clients.end()) found->second->Close();
}
void VaneQuit() {
  CEF_REQUIRE_UI_THREAD();
  if (quitting) return;
  quitting = true;
  if (clients.empty()) {
    MaybeQuit();
    return;
  }
  // Closing a browser can reenter callbacks; keep this iteration independent.
  std::vector<CefRefPtr<BrowserClient>> snapshot;
  for (const auto &[token, client] : clients) snapshot.push_back(client);
  for (auto &client : snapshot) client->Close();
}
const char *VaneProfilePath() { return profile_path.c_str(); }
const char *VaneStartupURL() { return startup_url.c_str(); }

int main(int argc, char *argv[]) {
  CefScopedLibraryLoader loader;
  if (!loader.LoadInMain()) return 1;
  @autoreleasepool {
    [VaneChromiumApplication sharedApplication];
    if (![NSApp isKindOfClass:VaneChromiumApplication.class]) return 1;
    CefRefPtr<CefCommandLine> command = CefCommandLine::CreateCommandLine();
    command->InitFromArgv(argc, argv);
    smoke = command->HasSwitch("vane-smoke");
    NSString *defaultPath = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Application Support/Vane Chromium Prototype"];
    profile_path = command->HasSwitch("vane-profile")
        ? command->GetSwitchValue("vane-profile").ToString() : defaultPath.UTF8String;
    if (profile_path.empty() || profile_path.front() != '/') {
      fprintf(stderr, "--vane-profile must be an absolute, prototype-only directory\n");
      return 2;
    }
    // CEF canonicalizes root_cache_path itself. Resolve /var -> /private/var
    // before deriving cache_path, or a disposable profile silently becomes RAM-only.
    NSString *requestedPath = [NSString stringWithUTF8String:profile_path.c_str()];
    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:requestedPath
        withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
      fprintf(stderr, "Cannot create prototype profile: %s\n", directoryError.localizedDescription.UTF8String);
      return 2;
    }
    char canonicalPath[PATH_MAX];
    if (!realpath(profile_path.c_str(), canonicalPath)) {
      perror("Cannot resolve prototype profile");
      return 2;
    }
    profile_path = canonicalPath;
    NSString *home = [NSBundle.mainBundle pathForResource:@"start" ofType:@"html"];
    startup_url = command->HasSwitch("url") ? command->GetSwitchValue("url").ToString()
        : [NSURL fileURLWithPath:home].absoluteString.UTF8String;
    CefSettings settings;
    CefString(&settings.root_cache_path) = profile_path;
    CefString(&settings.cache_path) = profile_path + "/Default";
    settings.log_severity = LOGSEVERITY_WARNING;
    CefString(&settings.log_file) = profile_path + "/chromium.log";
    CefMainArgs args(argc, argv);
    CefRefPtr<PrototypeApp> app = new PrototypeApp;
    if (!CefInitialize(args, settings, app, nullptr)) return CefGetExitCode();
    fprintf(stdout, "Vane Chromium Prototype: profile=%s sandbox=enabled\n", profile_path.c_str());
    fflush(stdout);
    CefRunMessageLoop();
    CefShutdown();
  }
  return smoke ? smoke_result : 0;
}
