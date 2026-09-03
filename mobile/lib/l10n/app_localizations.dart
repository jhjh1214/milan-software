import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ms.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of L
/// returned by `L.of(context)`.
///
/// Applications need to include `L.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: L.localizationsDelegates,
///   supportedLocales: L.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the L.supportedLocales
/// property.
abstract class L {
  L(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static L of(BuildContext context) {
    return Localizations.of<L>(context, L)!;
  }

  static const LocalizationsDelegate<L> delegate = _LDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ms'),
    Locale('zh'),
  ];

  /// App name shown in the launcher and app bar
  ///
  /// In zh, this message translates to:
  /// **'米兰报价'**
  String get appTitle;

  /// No description provided for @languageChinese.
  ///
  /// In zh, this message translates to:
  /// **'中文'**
  String get languageChinese;

  /// No description provided for @languageEnglish.
  ///
  /// In zh, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @languageMalay.
  ///
  /// In zh, this message translates to:
  /// **'Bahasa Melayu'**
  String get languageMalay;

  /// No description provided for @language.
  ///
  /// In zh, this message translates to:
  /// **'语言'**
  String get language;

  /// No description provided for @quoteTitle.
  ///
  /// In zh, this message translates to:
  /// **'报价'**
  String get quoteTitle;

  /// No description provided for @newQuote.
  ///
  /// In zh, this message translates to:
  /// **'新报价'**
  String get newQuote;

  /// No description provided for @addWindow.
  ///
  /// In zh, this message translates to:
  /// **'加窗口'**
  String get addWindow;

  /// No description provided for @emptyQuoteTitle.
  ///
  /// In zh, this message translates to:
  /// **'还没有窗口'**
  String get emptyQuoteTitle;

  /// No description provided for @emptyQuoteAction.
  ///
  /// In zh, this message translates to:
  /// **'按下面的按钮加第一个窗口'**
  String get emptyQuoteAction;

  /// No description provided for @stepRoom.
  ///
  /// In zh, this message translates to:
  /// **'哪个房间？'**
  String get stepRoom;

  /// No description provided for @stepProduct.
  ///
  /// In zh, this message translates to:
  /// **'什么产品？'**
  String get stepProduct;

  /// No description provided for @stepMaterial.
  ///
  /// In zh, this message translates to:
  /// **'什么料？'**
  String get stepMaterial;

  /// No description provided for @stepSizes.
  ///
  /// In zh, this message translates to:
  /// **'尺寸'**
  String get stepSizes;

  /// No description provided for @stepUpgrade.
  ///
  /// In zh, this message translates to:
  /// **'要加什么吗？'**
  String get stepUpgrade;

  /// No description provided for @upgradeNone.
  ///
  /// In zh, this message translates to:
  /// **'不用，就这样'**
  String get upgradeNone;

  /// No description provided for @upgradeIncluded.
  ///
  /// In zh, this message translates to:
  /// **'普通轨道已包在价格里，以下是升级选项'**
  String get upgradeIncluded;

  /// No description provided for @upgradeAdded.
  ///
  /// In zh, this message translates to:
  /// **'已加 {name}'**
  String upgradeAdded(String name);

  /// No description provided for @upgradeOf.
  ///
  /// In zh, this message translates to:
  /// **'配 {parent}'**
  String upgradeOf(String parent);

  /// No description provided for @stepFamily.
  ///
  /// In zh, this message translates to:
  /// **'哪一类？'**
  String get stepFamily;

  /// No description provided for @familyCurtain.
  ///
  /// In zh, this message translates to:
  /// **'窗帘'**
  String get familyCurtain;

  /// No description provided for @familyBlind.
  ///
  /// In zh, this message translates to:
  /// **'百叶 / 卷帘'**
  String get familyBlind;

  /// No description provided for @familyTrack.
  ///
  /// In zh, this message translates to:
  /// **'轨道 / 杆'**
  String get familyTrack;

  /// No description provided for @familyFlooring.
  ///
  /// In zh, this message translates to:
  /// **'地板'**
  String get familyFlooring;

  /// No description provided for @familyWallpaper.
  ///
  /// In zh, this message translates to:
  /// **'壁纸'**
  String get familyWallpaper;

  /// No description provided for @familyAddon.
  ///
  /// In zh, this message translates to:
  /// **'配件'**
  String get familyAddon;

  /// No description provided for @familyService.
  ///
  /// In zh, this message translates to:
  /// **'服务'**
  String get familyService;

  /// No description provided for @materialLater.
  ///
  /// In zh, this message translates to:
  /// **'料丈量时再选'**
  String get materialLater;

  /// No description provided for @materialLaterNote.
  ///
  /// In zh, this message translates to:
  /// **'报价按最贵的料算，选了较便宜的会更低。'**
  String get materialLaterNote;

  /// No description provided for @stepProgress.
  ///
  /// In zh, this message translates to:
  /// **'第 {current} 个，共 {total} 个 · {room}'**
  String stepProgress(int current, int total, String room);

  /// No description provided for @roomLiving.
  ///
  /// In zh, this message translates to:
  /// **'客厅'**
  String get roomLiving;

  /// No description provided for @roomMaster.
  ///
  /// In zh, this message translates to:
  /// **'主人房'**
  String get roomMaster;

  /// No description provided for @roomBedroom.
  ///
  /// In zh, this message translates to:
  /// **'房间'**
  String get roomBedroom;

  /// No description provided for @roomKitchen.
  ///
  /// In zh, this message translates to:
  /// **'厨房'**
  String get roomKitchen;

  /// No description provided for @roomBalcony.
  ///
  /// In zh, this message translates to:
  /// **'阳台'**
  String get roomBalcony;

  /// No description provided for @roomStudy.
  ///
  /// In zh, this message translates to:
  /// **'书房'**
  String get roomStudy;

  /// No description provided for @roomOther.
  ///
  /// In zh, this message translates to:
  /// **'其他'**
  String get roomOther;

  /// No description provided for @roomCustom.
  ///
  /// In zh, this message translates to:
  /// **'自己填'**
  String get roomCustom;

  /// No description provided for @width.
  ///
  /// In zh, this message translates to:
  /// **'宽'**
  String get width;

  /// No description provided for @height.
  ///
  /// In zh, this message translates to:
  /// **'高'**
  String get height;

  /// No description provided for @quantity.
  ///
  /// In zh, this message translates to:
  /// **'数量'**
  String get quantity;

  /// No description provided for @sameWindows.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个一样的窗口'**
  String sameWindows(int count);

  /// No description provided for @unitFoot.
  ///
  /// In zh, this message translates to:
  /// **'尺'**
  String get unitFoot;

  /// No description provided for @unitInch.
  ///
  /// In zh, this message translates to:
  /// **'寸'**
  String get unitInch;

  /// No description provided for @unitMm.
  ///
  /// In zh, this message translates to:
  /// **'毫米'**
  String get unitMm;

  /// No description provided for @unitCm.
  ///
  /// In zh, this message translates to:
  /// **'厘米'**
  String get unitCm;

  /// No description provided for @unitMetre.
  ///
  /// In zh, this message translates to:
  /// **'米'**
  String get unitMetre;

  /// No description provided for @unitSqft.
  ///
  /// In zh, this message translates to:
  /// **'平方尺'**
  String get unitSqft;

  /// Shows the billed quantity beside the entered one
  ///
  /// In zh, this message translates to:
  /// **'按 {qty} {unit}计'**
  String billedAs(String qty, String unit);

  /// No description provided for @enteredAs.
  ///
  /// In zh, this message translates to:
  /// **'输入 {value}'**
  String enteredAs(String value);

  /// Shown on a line whose billed quantity was lifted to the product minimum
  ///
  /// In zh, this message translates to:
  /// **'最低 {qty} {unit}'**
  String minQtyApplied(String qty, String unit);

  /// No description provided for @errorInvalidDimension.
  ///
  /// In zh, this message translates to:
  /// **'看不懂这个尺寸'**
  String get errorInvalidDimension;

  /// No description provided for @errorDimensionRequired.
  ///
  /// In zh, this message translates to:
  /// **'请填尺寸'**
  String get errorDimensionRequired;

  /// No description provided for @errorNoRate.
  ///
  /// In zh, this message translates to:
  /// **'这个产品的价格资料不齐全，请通知公司'**
  String get errorNoRate;

  /// No description provided for @warnUnitLooksWrong.
  ///
  /// In zh, this message translates to:
  /// **'{value} {unit} = {converted}，是不是要打 {suggestion}？'**
  String warnUnitLooksWrong(
    String value,
    String unit,
    String converted,
    String suggestion,
  );

  /// No description provided for @warnSwitchTo.
  ///
  /// In zh, this message translates to:
  /// **'改成 {unit}'**
  String warnSwitchTo(String unit);

  /// No description provided for @warnDropVeryShort.
  ///
  /// In zh, this message translates to:
  /// **'高度只有 {value}，确认吗？'**
  String warnDropVeryShort(String value);

  /// No description provided for @warnNearBandEdge.
  ///
  /// In zh, this message translates to:
  /// **'刚刚超过 {edge}，请确认尺寸'**
  String warnNearBandEdge(String edge);

  /// No description provided for @warnBandBothPrices.
  ///
  /// In zh, this message translates to:
  /// **'{lower} 以内 {lowerPrice} · 超过 {upper}'**
  String warnBandBothPrices(String lower, String lowerPrice, String upper);

  /// No description provided for @runningTotal.
  ///
  /// In zh, this message translates to:
  /// **'总额'**
  String get runningTotal;

  /// No description provided for @customerTitle.
  ///
  /// In zh, this message translates to:
  /// **'客户资料'**
  String get customerTitle;

  /// No description provided for @customerName.
  ///
  /// In zh, this message translates to:
  /// **'客户姓名'**
  String get customerName;

  /// No description provided for @customerPhone.
  ///
  /// In zh, this message translates to:
  /// **'电话'**
  String get customerPhone;

  /// No description provided for @customerOptional.
  ///
  /// In zh, this message translates to:
  /// **'可以不填，之后再补'**
  String get customerOptional;

  /// No description provided for @deliveryTitle.
  ///
  /// In zh, this message translates to:
  /// **'送货地区'**
  String get deliveryTitle;

  /// No description provided for @deliveryNone.
  ///
  /// In zh, this message translates to:
  /// **'马六甲市区（不加钱）'**
  String get deliveryNone;

  /// No description provided for @deliveryCharge.
  ///
  /// In zh, this message translates to:
  /// **'路费 {area}'**
  String deliveryCharge(String area);

  /// No description provided for @deliveryAskEarly.
  ///
  /// In zh, this message translates to:
  /// **'先问地区，免得报了价才加钱'**
  String get deliveryAskEarly;

  /// No description provided for @save.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get save;

  /// No description provided for @ratesTitle.
  ///
  /// In zh, this message translates to:
  /// **'价格表'**
  String get ratesTitle;

  /// No description provided for @ratesEditOne.
  ///
  /// In zh, this message translates to:
  /// **'改单项价格'**
  String get ratesEditOne;

  /// No description provided for @ratesSearch.
  ///
  /// In zh, this message translates to:
  /// **'搜索产品'**
  String get ratesSearch;

  /// No description provided for @ratesNewRate.
  ///
  /// In zh, this message translates to:
  /// **'新价格 (RM)'**
  String get ratesNewRate;

  /// No description provided for @ratesNewMvp.
  ///
  /// In zh, this message translates to:
  /// **'MVP 价格 (RM)'**
  String get ratesNewMvp;

  /// No description provided for @ratesCurrent.
  ///
  /// In zh, this message translates to:
  /// **'现价 {rate}'**
  String ratesCurrent(String rate);

  /// No description provided for @ratesInvalid.
  ///
  /// In zh, this message translates to:
  /// **'价格填错了'**
  String get ratesInvalid;

  /// No description provided for @ratesMvpTooHigh.
  ///
  /// In zh, this message translates to:
  /// **'MVP 价不可以高过普通价'**
  String get ratesMvpTooHigh;

  /// No description provided for @ratesNoMatch.
  ///
  /// In zh, this message translates to:
  /// **'找不到产品'**
  String get ratesNoMatch;

  /// No description provided for @ratesVersion.
  ///
  /// In zh, this message translates to:
  /// **'版本 {version} · {count} 项'**
  String ratesVersion(int version, int count);

  /// No description provided for @ratesExport.
  ///
  /// In zh, this message translates to:
  /// **'导出 Excel 档'**
  String get ratesExport;

  /// No description provided for @ratesImport.
  ///
  /// In zh, this message translates to:
  /// **'导入改好的档'**
  String get ratesImport;

  /// No description provided for @ratesNoChanges.
  ///
  /// In zh, this message translates to:
  /// **'没有价格改动'**
  String get ratesNoChanges;

  /// No description provided for @ratesReview.
  ///
  /// In zh, this message translates to:
  /// **'{count} 项价格有改动，确认后才生效'**
  String ratesReview(int count);

  /// No description provided for @ratesApply.
  ///
  /// In zh, this message translates to:
  /// **'确认更新价格'**
  String get ratesApply;

  /// No description provided for @ratesApplied.
  ///
  /// In zh, this message translates to:
  /// **'价格已更新到版本 {version}'**
  String ratesApplied(int version);

  /// No description provided for @ratesErrors.
  ///
  /// In zh, this message translates to:
  /// **'档案有问题，未更新任何价格'**
  String get ratesErrors;

  /// No description provided for @ratesRestore.
  ///
  /// In zh, this message translates to:
  /// **'还原原本价格表'**
  String get ratesRestore;

  /// No description provided for @ratesCustom.
  ///
  /// In zh, this message translates to:
  /// **'价格表已被修改（版本 {version}）'**
  String ratesCustom(int version);

  /// No description provided for @share.
  ///
  /// In zh, this message translates to:
  /// **'分享报价'**
  String get share;

  /// No description provided for @pdfTitle.
  ///
  /// In zh, this message translates to:
  /// **'报价单'**
  String get pdfTitle;

  /// No description provided for @pdfCompany.
  ///
  /// In zh, this message translates to:
  /// **'米兰窗帘地板'**
  String get pdfCompany;

  /// No description provided for @pdfQuoteNo.
  ///
  /// In zh, this message translates to:
  /// **'报价编号'**
  String get pdfQuoteNo;

  /// No description provided for @pdfDate.
  ///
  /// In zh, this message translates to:
  /// **'日期'**
  String get pdfDate;

  /// No description provided for @pdfRoom.
  ///
  /// In zh, this message translates to:
  /// **'房间'**
  String get pdfRoom;

  /// No description provided for @pdfProduct.
  ///
  /// In zh, this message translates to:
  /// **'产品'**
  String get pdfProduct;

  /// No description provided for @pdfSize.
  ///
  /// In zh, this message translates to:
  /// **'尺寸'**
  String get pdfSize;

  /// No description provided for @pdfBilled.
  ///
  /// In zh, this message translates to:
  /// **'计算'**
  String get pdfBilled;

  /// No description provided for @pdfRate.
  ///
  /// In zh, this message translates to:
  /// **'单价'**
  String get pdfRate;

  /// No description provided for @pdfAmount.
  ///
  /// In zh, this message translates to:
  /// **'金额'**
  String get pdfAmount;

  /// No description provided for @pdfNotAnInvoice.
  ///
  /// In zh, this message translates to:
  /// **'此单不是税务发票，只是报价参考。'**
  String get pdfNotAnInvoice;

  /// No description provided for @pdfValidity.
  ///
  /// In zh, this message translates to:
  /// **'报价有效期 {days} 天'**
  String pdfValidity(int days);

  /// No description provided for @pdfPage.
  ///
  /// In zh, this message translates to:
  /// **'第 {page} 页，共 {total} 页'**
  String pdfPage(int page, int total);

  /// No description provided for @subtotal.
  ///
  /// In zh, this message translates to:
  /// **'小计'**
  String get subtotal;

  /// No description provided for @lineTotal.
  ///
  /// In zh, this message translates to:
  /// **'小计'**
  String get lineTotal;

  /// The RM300 per-category floor, shown as its own row and never folded into the lines
  ///
  /// In zh, this message translates to:
  /// **'最低报价（订金 {amount}）'**
  String depositFloorRow(String amount);

  /// No description provided for @depositFloorExplain.
  ///
  /// In zh, this message translates to:
  /// **'报价不会低过订金，免得订金比货还贵。'**
  String get depositFloorExplain;

  /// No description provided for @disclaimerTitle.
  ///
  /// In zh, this message translates to:
  /// **'参考价'**
  String get disclaimerTitle;

  /// No description provided for @disclaimerBody.
  ///
  /// In zh, this message translates to:
  /// **'此报价按整数进位计算，仅供参考。现场实际丈量后，价格只会相同或更低，不会更高。'**
  String get disclaimerBody;

  /// No description provided for @provisionalCardBanner.
  ///
  /// In zh, this message translates to:
  /// **'价格表还没确认，不可以给客户报价'**
  String get provisionalCardBanner;

  /// No description provided for @listFair.
  ///
  /// In zh, this message translates to:
  /// **'展会价 {code}'**
  String listFair(String code);

  /// No description provided for @listStandard.
  ///
  /// In zh, this message translates to:
  /// **'平时价（非展会）'**
  String get listStandard;

  /// No description provided for @listStandardProvisional.
  ///
  /// In zh, this message translates to:
  /// **'平时价暂定：窗帘加 20%，百叶加 50%。其他（轨道、地板、壁纸、配件）全年同价。'**
  String get listStandardProvisional;

  /// No description provided for @expiredCardBanner.
  ///
  /// In zh, this message translates to:
  /// **'这是 {code} 展会价，{date} 已过期。日常报价不可以用。'**
  String expiredCardBanner(String code, String date);

  /// No description provided for @delete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get delete;

  /// No description provided for @deleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除'**
  String get deleted;

  /// No description provided for @undo.
  ///
  /// In zh, this message translates to:
  /// **'还原'**
  String get undo;

  /// No description provided for @back.
  ///
  /// In zh, this message translates to:
  /// **'返回'**
  String get back;

  /// No description provided for @next.
  ///
  /// In zh, this message translates to:
  /// **'下一步'**
  String get next;

  /// No description provided for @done.
  ///
  /// In zh, this message translates to:
  /// **'完成'**
  String get done;

  /// No description provided for @cancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get cancel;

  /// No description provided for @confirm.
  ///
  /// In zh, this message translates to:
  /// **'确认'**
  String get confirm;

  /// No description provided for @keypadClear.
  ///
  /// In zh, this message translates to:
  /// **'清除'**
  String get keypadClear;

  /// No description provided for @keypadBackspace.
  ///
  /// In zh, this message translates to:
  /// **'退格'**
  String get keypadBackspace;

  /// No description provided for @keypadDone.
  ///
  /// In zh, this message translates to:
  /// **'好'**
  String get keypadDone;

  /// No description provided for @bandLower.
  ///
  /// In zh, this message translates to:
  /// **'10 尺以内'**
  String get bandLower;

  /// No description provided for @bandUpper.
  ///
  /// In zh, this message translates to:
  /// **'超过 10 尺'**
  String get bandUpper;

  /// No description provided for @tierMvp.
  ///
  /// In zh, this message translates to:
  /// **'MVP 会员价'**
  String get tierMvp;

  /// No description provided for @tierStandard.
  ///
  /// In zh, this message translates to:
  /// **'普通价'**
  String get tierStandard;

  /// No description provided for @roleAdmin.
  ///
  /// In zh, this message translates to:
  /// **'管理员'**
  String get roleAdmin;

  /// No description provided for @roleStaff.
  ///
  /// In zh, this message translates to:
  /// **'员工'**
  String get roleStaff;

  /// No description provided for @roleParttime.
  ///
  /// In zh, this message translates to:
  /// **'临时员工'**
  String get roleParttime;

  /// No description provided for @syncTitle.
  ///
  /// In zh, this message translates to:
  /// **'同步'**
  String get syncTitle;

  /// No description provided for @signInTitle.
  ///
  /// In zh, this message translates to:
  /// **'登入'**
  String get signInTitle;

  /// No description provided for @signInPhone.
  ///
  /// In zh, this message translates to:
  /// **'手机号码'**
  String get signInPhone;

  /// No description provided for @signInPin.
  ///
  /// In zh, this message translates to:
  /// **'密码 PIN'**
  String get signInPin;

  /// No description provided for @signInAction.
  ///
  /// In zh, this message translates to:
  /// **'登入'**
  String get signInAction;

  /// No description provided for @signInFailed.
  ///
  /// In zh, this message translates to:
  /// **'号码或密码不对'**
  String get signInFailed;

  /// No description provided for @signInOffline.
  ///
  /// In zh, this message translates to:
  /// **'没有网络。有信号时再试。'**
  String get signInOffline;

  /// No description provided for @signInBusy.
  ///
  /// In zh, this message translates to:
  /// **'试太多次了。请等 {seconds} 秒。'**
  String signInBusy(int seconds);

  /// No description provided for @signInWhy.
  ///
  /// In zh, this message translates to:
  /// **'出展前登入一次就好。之后没有网络也照样用。'**
  String get signInWhy;

  /// No description provided for @signedInAs.
  ///
  /// In zh, this message translates to:
  /// **'已登入：{name}（{role}）'**
  String signedInAs(String name, String role);

  /// No description provided for @signOut.
  ///
  /// In zh, this message translates to:
  /// **'登出'**
  String get signOut;

  /// No description provided for @notSignedIn.
  ///
  /// In zh, this message translates to:
  /// **'还没登入。报价照常，只是不会传回公司。'**
  String get notSignedIn;

  /// No description provided for @serverAddress.
  ///
  /// In zh, this message translates to:
  /// **'服务器地址'**
  String get serverAddress;

  /// No description provided for @serverAddressInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请输入 https 地址，例如 milan.example.com'**
  String get serverAddressInvalid;

  /// No description provided for @serverAddressChanged.
  ///
  /// In zh, this message translates to:
  /// **'服务器已更改，请重新登入。'**
  String get serverAddressChanged;

  /// No description provided for @syncNow.
  ///
  /// In zh, this message translates to:
  /// **'立即同步'**
  String get syncNow;

  /// No description provided for @syncRunning.
  ///
  /// In zh, this message translates to:
  /// **'同步中'**
  String get syncRunning;

  /// No description provided for @syncNever.
  ///
  /// In zh, this message translates to:
  /// **'还没同步过'**
  String get syncNever;

  /// No description provided for @syncLastAt.
  ///
  /// In zh, this message translates to:
  /// **'上次同步：{time}'**
  String syncLastAt(String time);

  /// No description provided for @syncOffline.
  ///
  /// In zh, this message translates to:
  /// **'没有网络。一切照常，稍后自动补上。'**
  String get syncOffline;

  /// No description provided for @syncSignedOut.
  ///
  /// In zh, this message translates to:
  /// **'这台手机已被登出。请重新登入才能上传报价。'**
  String get syncSignedOut;

  /// No description provided for @syncPricesUpdated.
  ///
  /// In zh, this message translates to:
  /// **'价格已更新到第 {version} 版'**
  String syncPricesUpdated(int version);

  /// No description provided for @syncPricesCurrent.
  ///
  /// In zh, this message translates to:
  /// **'价格已是最新'**
  String get syncPricesCurrent;

  /// No description provided for @syncQueued.
  ///
  /// In zh, this message translates to:
  /// **'有 {count} 张报价等着上传'**
  String syncQueued(int count);

  /// No description provided for @syncSent.
  ///
  /// In zh, this message translates to:
  /// **'已上传 {count} 张报价'**
  String syncSent(int count);

  /// No description provided for @syncParked.
  ///
  /// In zh, this message translates to:
  /// **'有 {count} 张报价需要处理'**
  String syncParked(int count);

  /// No description provided for @syncDisagreed.
  ///
  /// In zh, this message translates to:
  /// **'有 {count} 张报价公司算出的价格不一样。订单照收，已标记待查。'**
  String syncDisagreed(int count);

  /// No description provided for @syncLocalEditDropped.
  ///
  /// In zh, this message translates to:
  /// **'这台手机改过的价格已被公司的价格表取代。'**
  String get syncLocalEditDropped;

  /// No description provided for @pricesFromServer.
  ///
  /// In zh, this message translates to:
  /// **'价格来自公司，{time} 更新'**
  String pricesFromServer(String time);

  /// No description provided for @pricesBundled.
  ///
  /// In zh, this message translates to:
  /// **'这是随程序附带的价格。登入后会取得公司的价格表。'**
  String get pricesBundled;

  /// No description provided for @pricesLocal.
  ///
  /// In zh, this message translates to:
  /// **'这是在这台手机上改过的价格，下次同步会被取代。'**
  String get pricesLocal;

  /// No description provided for @ratesServerOwned.
  ///
  /// In zh, this message translates to:
  /// **'价格由公司统一发布，每台手机报价一致。在这里的更改会发布给所有人。'**
  String get ratesServerOwned;

  /// No description provided for @ratesPublish.
  ///
  /// In zh, this message translates to:
  /// **'发布给所有人'**
  String get ratesPublish;

  /// No description provided for @ratesPublished.
  ///
  /// In zh, this message translates to:
  /// **'已发布第 {version} 版。每台手机下次同步就会收到。'**
  String ratesPublished(int version);

  /// No description provided for @ratesPublishOffline.
  ///
  /// In zh, this message translates to:
  /// **'发布需要网络，这样每台手机才拿到同一份价格表。'**
  String get ratesPublishOffline;

  /// No description provided for @ratesReadOnly.
  ///
  /// In zh, this message translates to:
  /// **'只有公司可以更改价格。'**
  String get ratesReadOnly;

  /// No description provided for @ratesCheckUpdates.
  ///
  /// In zh, this message translates to:
  /// **'检查更新'**
  String get ratesCheckUpdates;

  /// No description provided for @fairModeTitle.
  ///
  /// In zh, this message translates to:
  /// **'展销模式'**
  String get fairModeTitle;

  /// No description provided for @fairModePrepare.
  ///
  /// In zh, this message translates to:
  /// **'出展前准备'**
  String get fairModePrepare;

  /// No description provided for @fairModeWhy.
  ///
  /// In zh, this message translates to:
  /// **'下载两份价格表并清空上传队列，手机就能连续几天没网络也照用。'**
  String get fairModeWhy;

  /// No description provided for @fairModeReady.
  ///
  /// In zh, this message translates to:
  /// **'准备好了。两份价格表都是最新，也没有待上传的报价。'**
  String get fairModeReady;

  /// No description provided for @fairModeNotReady.
  ///
  /// In zh, this message translates to:
  /// **'还没准备好。出发前请连上网络再试一次。'**
  String get fairModeNotReady;

  /// No description provided for @atFair.
  ///
  /// In zh, this message translates to:
  /// **'在展销会'**
  String get atFair;

  /// No description provided for @atFairHelp.
  ///
  /// In zh, this message translates to:
  /// **'用促销价，RM300 可以锁价 12 个月。展销会结束后会自动关掉。'**
  String get atFairHelp;

  /// No description provided for @atFairEnded.
  ///
  /// In zh, this message translates to:
  /// **'展销会已在 {date} 结束，现在是平时价。'**
  String atFairEnded(String date);

  /// No description provided for @channelFair.
  ///
  /// In zh, this message translates to:
  /// **'展销会'**
  String get channelFair;

  /// No description provided for @channelShowroom.
  ///
  /// In zh, this message translates to:
  /// **'店里'**
  String get channelShowroom;

  /// No description provided for @depositNeededTitle.
  ///
  /// In zh, this message translates to:
  /// **'这单有{category}'**
  String depositNeededTitle(String category);

  /// No description provided for @depositNeededBody.
  ///
  /// In zh, this message translates to:
  /// **'{category}要另外 {amount}，才可以锁住促销价 12 个月。'**
  String depositNeededBody(String category, String amount);

  /// No description provided for @depositCollect.
  ///
  /// In zh, this message translates to:
  /// **'收 {amount}'**
  String depositCollect(String amount);

  /// No description provided for @depositDecline.
  ///
  /// In zh, this message translates to:
  /// **'不锁价，照今天的价'**
  String get depositDecline;

  /// No description provided for @depositRemove.
  ///
  /// In zh, this message translates to:
  /// **'取消{category}'**
  String depositRemove(String category);

  /// No description provided for @depositCollected.
  ///
  /// In zh, this message translates to:
  /// **'已记录 {amount}。{category}价格锁到 {date}。'**
  String depositCollected(String amount, String category, String date);

  /// No description provided for @depositDeclined.
  ///
  /// In zh, this message translates to:
  /// **'知道了。{category}没有锁价。'**
  String depositDeclined(String category);

  /// No description provided for @depositNotAtFair.
  ///
  /// In zh, this message translates to:
  /// **'只有在展销会付的 RM300 才能锁价。'**
  String get depositNotAtFair;

  /// No description provided for @categoryCurtain.
  ///
  /// In zh, this message translates to:
  /// **'窗帘'**
  String get categoryCurtain;

  /// No description provided for @categoryFlooring.
  ///
  /// In zh, this message translates to:
  /// **'地板'**
  String get categoryFlooring;

  /// No description provided for @categoryWallpaper.
  ///
  /// In zh, this message translates to:
  /// **'壁纸'**
  String get categoryWallpaper;

  /// No description provided for @paymentMethodTitle.
  ///
  /// In zh, this message translates to:
  /// **'怎么付？'**
  String get paymentMethodTitle;

  /// No description provided for @methodCash.
  ///
  /// In zh, this message translates to:
  /// **'现金'**
  String get methodCash;

  /// No description provided for @methodCard.
  ///
  /// In zh, this message translates to:
  /// **'刷卡'**
  String get methodCard;

  /// No description provided for @methodDuitnow.
  ///
  /// In zh, this message translates to:
  /// **'DuitNow'**
  String get methodDuitnow;

  /// No description provided for @methodTransfer.
  ///
  /// In zh, this message translates to:
  /// **'银行转账'**
  String get methodTransfer;

  /// No description provided for @methodCheque.
  ///
  /// In zh, this message translates to:
  /// **'支票'**
  String get methodCheque;

  /// No description provided for @receiptPending.
  ///
  /// In zh, this message translates to:
  /// **'收据号码等同步'**
  String get receiptPending;

  /// No description provided for @paymentsTaken.
  ///
  /// In zh, this message translates to:
  /// **'已收 {amount}'**
  String paymentsTaken(String amount);

  /// No description provided for @cashUpTitle.
  ///
  /// In zh, this message translates to:
  /// **'今天收的钱'**
  String get cashUpTitle;

  /// No description provided for @cashUpExpected.
  ///
  /// In zh, this message translates to:
  /// **'应该有'**
  String get cashUpExpected;

  /// No description provided for @cashUpCounted.
  ///
  /// In zh, this message translates to:
  /// **'实际点到'**
  String get cashUpCounted;

  /// No description provided for @cashUpShort.
  ///
  /// In zh, this message translates to:
  /// **'少了'**
  String get cashUpShort;

  /// No description provided for @cashUpOver.
  ///
  /// In zh, this message translates to:
  /// **'多了'**
  String get cashUpOver;

  /// No description provided for @cashUpBalanced.
  ///
  /// In zh, this message translates to:
  /// **'对得上，没问题。'**
  String get cashUpBalanced;

  /// No description provided for @cashUpNothingTaken.
  ///
  /// In zh, this message translates to:
  /// **'今天还没收到钱。'**
  String get cashUpNothingTaken;

  /// No description provided for @cashUpNotCounted.
  ///
  /// In zh, this message translates to:
  /// **'还有 {count} 项现金没点。点了才算数。'**
  String cashUpNotCounted(int count);

  /// No description provided for @cashUpOff.
  ///
  /// In zh, this message translates to:
  /// **'{method}{direction} {amount}。'**
  String cashUpOff(String method, String amount, String direction);
}

class _LDelegate extends LocalizationsDelegate<L> {
  const _LDelegate();

  @override
  Future<L> load(Locale locale) {
    return SynchronousFuture<L>(lookupL(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ms', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_LDelegate old) => false;
}

L lookupL(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return LEn();
    case 'ms':
      return LMs();
    case 'zh':
      return LZh();
  }

  throw FlutterError(
    'L.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
