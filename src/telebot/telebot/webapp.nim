import std/jsffi

type
  WebAppEvents* = enum
    THEME_CHANGED = "themeChanged"
    VIEWPORT_CHANGED = "viewportChanged"
    MAIN_BUTTON_CLICKED = "mainButtonClicked"
    BACk_BUTTON_CLICKED = "backButtonClicked"
    SETTINGS_BUTTON_CLICKED = "settingsButtonClicked"
    INVOICE_CLOSE = "invoiceClosed"
    POPUP_CLOSED = "popupClosed"

  WebAppInitData* = object
    query_id*: string
    user*: WebAppUser
    receiver*: WebAppUser
    chat*: WebAppChat
    start_param: string
    can_send_after*: int64
    auth_date*: int64
    hash*: string

  WebAppUser* {.importc, nodecl.} = object
    id*: int64
    is_bot*: bool
    first_name*: string
    last_name*: string
    username*: string
    language_code*: string
    isPremium*: bool
    photo_url*: string

  WebAppChat* {.importc, nodecl.} = object
    id*: int64
    `type`*: string
    title*: string
    username*: string
    photo_url*: string


  BackButton* {.importc, nodecl.} = object
    isVisible*: bool

  MainButton* {.importc, nodecl.} = object
    text*: string
    color*: string
    textColor*: string
    isVisible*: bool
    isActive*: bool
    isProgressVisible*: bool

  HapticFeedback* {.importc, nodecl.} = object

  ThemeParams* {.importc, nodecl.} = object
    bg_color*: string
    text_color*: string
    hint_color*: string
    link_color*: string
    button_color*: string
    button_text_color*: string
    secondary_bg_color*: string

  PopupButton* {.importc, nodecl.} = object
    id*: string
    `type`*: string
    text*: string

  PopupParams* {.importc, nodecl.} = object
    title*: string
    message*: string
    buttons*: seq[PopupButton]

  WebApp* = ref WebAppObj
  WebAppObj* {.importc, nodecl.} = object of RootObj
    initData*: string
    initDataUnsafe*: WebAppInitData
    version*: string
    colorScheme*: string
    themeParams*: ThemeParams
    isExpanded*: bool
    viewportHeight*: float
    viewportStableHeight*: float
    headerColor*: string
    backgroundColor*: string
    isClosingConfirmationEnabled*: bool
    BackButton*: BackButton
    MainButton*: MainButton
    HapticFeedback*: HapticFeedback

  TelegramObj* {.importc, nodecl.} = object of RootObj
    WebApp*: WebApp

  TelegramRef* = ref TelegramObj

  EventHandler = proc()

var Telegram* {.importc, nodecl.}: TelegramRef

#--------
# WebApp
#--------
proc isVersionAtLeast*(w: WebApp, version: string): bool {.importc, nodecl.}
proc setHeaderColor*(w: WebApp, color: string) {.importc, nodecl.}
proc setBackgrounColor*(w: WebApp, color: string) {.importc, nodecl.}
proc enableClosingConfirmation*(w: WebApp) {.importc, nodecl.}
proc disableClosingConfirmation*(w: WebApp) {.importc, nodecl.}
proc onEvent*(w: WebApp, eventType: string, eventHandler: EventHandler) {.importc, nodecl.}
proc offEvent*(w: WebApp, eventType: string, eventHandler: EventHandler) {.importc, nodecl.}
proc sendData*(w: WebApp, data: string) {.importc, nodecl.}
proc openLink*(w: WebApp, url: string) {.importc, nodecl.}
proc openTelegramLink*(w: WebApp, url: string) {.importc, nodecl.}
proc openInvoice*(w: WebApp, url: string, callback: EventHandler = nil) {.importc, nodecl.}
proc showPopup*(w: WebApp, params: PopupParams, callback: EventHandler = nil) {.importc, nodecl.}
proc showAlert*(w: WebApp, message: string, callback: EventHandler = nil) {.importc, nodecl.}
proc showConfirm*(w: WebApp, message: string, callback: EventHandler = nil) {.importc, nodecl.}
proc ready*(w: WebApp): bool {.importc, nodecl.}
proc expand*(w: WebApp) {.importc, nodecl.}
proc close*(w: WebApp) {.importc, nodecl.}

#--------
# BackButtton
#--------
proc onClick*(b: BackButton, callback: EventHandler): BackButton {.importc, nodecl.}
proc offClick*(b: BackButton, callback: EventHandler): BackButton {.importc, nodecl.}
proc show*(b: BackButton): BackButton {.importc, nodecl.}
proc hide*(b: BackButton): BackButton {.importc, nodecl.}

#--------
# MainButtton
#--------
proc setText*(b: MainButton, text: string): MainButton {.importc, nodecl.}
proc onClick*(b: MainButton, callback: EventHandler): MainButton {.importc, nodecl.}
proc offClick*(b: MainButton, callback: EventHandler): MainButton {.importc, nodecl.}
proc show*(b: MainButton): MainButton {.importc, nodecl.}
proc hide*(b: MainButton): MainButton {.importc, nodecl.}
proc enable*(b: MainButton): MainButton {.importc, nodecl.}
proc disable*(b: MainButton): MainButton {.importc, nodecl.}
proc showProgress*(b: MainButton, leaveAction: bool): MainButton {.importc, nodecl.}
proc hideProgress*(b: MainButton): MainButton {.importc, nodecl.}
proc setParams*(b: MainButton, params: JsObject): MainButton {.importc, nodecl.}

#--------
# HapticFeedback
#--------
proc impactOccurred*(h: HapticFeedback, style: string): HapticFeedback {.importc, nodecl.}
proc notificationOccurred*(h: HapticFeedback, kind: string): HapticFeedback {.importc, nodecl.}
proc selectionChanged*(h: HapticFeedback): HapticFeedback {.importc, nodecl.}

