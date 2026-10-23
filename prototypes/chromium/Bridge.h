#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// CEF stays behind this boundary; the native shell has no WebKit dependency.
int32_t VaneCreateBrowser(const char *url);
void VaneSelectBrowser(int32_t token);
void VaneNavigate(int32_t token, const char *url);
void VaneGoBack(int32_t token);
void VaneGoForward(int32_t token);
void VaneReload(int32_t token);
void VaneFocusAddress(int32_t token);
void VaneCloseBrowser(int32_t token);
void VaneQuit(void);
const char *VaneProfilePath(void);
const char *VaneStartupURL(void);

// Swift callbacks, called only on CEF's UI thread (the macOS main thread).
void VaneStart(void);
void VaneCreateWindow(void *native_view, int32_t token);
void VaneWindowClosed(int32_t token);
void VaneBrowserChanged(int32_t token, const char *url, const char *title,
                        bool loading, bool back, bool forward);
void VaneBrowserClosed(int32_t token);

#ifdef __cplusplus
}
#endif
