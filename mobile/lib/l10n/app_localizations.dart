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

  /// No description provided for @upgradeRequired.
  ///
  /// In zh, this message translates to:
  /// **'这个产品一定要配，价钱已算在下面'**
  String get upgradeRequired;

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

  /// No description provided for @lengthDimension.
  ///
  /// In zh, this message translates to:
  /// **'长'**
  String get lengthDimension;

  /// No description provided for @dropDimension.
  ///
  /// In zh, this message translates to:
  /// **'高'**
  String get dropDimension;

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

  /// No description provided for @warnImplausibleSize.
  ///
  /// In zh, this message translates to:
  /// **'这是 {size}，请确认尺寸和单位'**
  String warnImplausibleSize(Object size);

  /// No description provided for @measureTitle.
  ///
  /// In zh, this message translates to:
  /// **'现场丈量'**
  String get measureTitle;

  /// No description provided for @measureEstimated.
  ///
  /// In zh, this message translates to:
  /// **'报价'**
  String get measureEstimated;

  /// No description provided for @measureFinal.
  ///
  /// In zh, this message translates to:
  /// **'丈量后'**
  String get measureFinal;

  /// No description provided for @measureNotYetPriced.
  ///
  /// In zh, this message translates to:
  /// **'还未定价'**
  String get measureNotYetPriced;

  /// No description provided for @measureEstimatedSize.
  ///
  /// In zh, this message translates to:
  /// **'报价尺寸'**
  String get measureEstimatedSize;

  /// No description provided for @measureMeasuredSize.
  ///
  /// In zh, this message translates to:
  /// **'实量尺寸'**
  String get measureMeasuredSize;

  /// No description provided for @measureThis.
  ///
  /// In zh, this message translates to:
  /// **'丈量'**
  String get measureThis;

  /// No description provided for @measureAgain.
  ///
  /// In zh, this message translates to:
  /// **'重新丈量'**
  String get measureAgain;

  /// No description provided for @measureQuotedAs.
  ///
  /// In zh, this message translates to:
  /// **'报价尺寸 {size}'**
  String measureQuotedAs(Object size);

  /// No description provided for @measureWasQuoted.
  ///
  /// In zh, this message translates to:
  /// **'报价 {size}'**
  String measureWasQuoted(Object size);

  /// No description provided for @measureChooseMaterial.
  ///
  /// In zh, this message translates to:
  /// **'选择材质'**
  String get measureChooseMaterial;

  /// No description provided for @measureUnderEstimate.
  ///
  /// In zh, this message translates to:
  /// **'比报价低 {amount}'**
  String measureUnderEstimate(Object amount);

  /// No description provided for @measureOverEstimate.
  ///
  /// In zh, this message translates to:
  /// **'比报价高 {amount} — 请核对尺寸'**
  String measureOverEstimate(Object amount);

  /// No description provided for @measureOutstanding.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, =1{还有 1 项未完成} other{还有 {count} 项未完成}}'**
  String measureOutstanding(num count);

  /// No description provided for @measureRefusedNotMeasured.
  ///
  /// In zh, this message translates to:
  /// **'还未丈量。'**
  String get measureRefusedNotMeasured;

  /// No description provided for @measureRefusedMaterial.
  ///
  /// In zh, this message translates to:
  /// **'还未选材质。'**
  String get measureRefusedMaterial;

  /// No description provided for @measureRefusedNoCard.
  ///
  /// In zh, this message translates to:
  /// **'这台手机没有这项报价时用的价目表。连一次网再试，不会按今天的价钱算。'**
  String get measureRefusedNoCard;

  /// No description provided for @measureRefusedNoRate.
  ///
  /// In zh, this message translates to:
  /// **'锁定的价目表里没有对应这项的价钱。'**
  String get measureRefusedNoRate;

  /// No description provided for @measureRefusedZero.
  ///
  /// In zh, this message translates to:
  /// **'这不是一个尺寸，请检查数字。'**
  String get measureRefusedZero;

  /// No description provided for @measureRefusedTerminal.
  ///
  /// In zh, this message translates to:
  /// **'这单已关闭或已取消。'**
  String get measureRefusedTerminal;

  /// No description provided for @measureRefusedNoLine.
  ///
  /// In zh, this message translates to:
  /// **'这一项不属于这单。'**
  String get measureRefusedNoLine;

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

  /// No description provided for @revisedTitle.
  ///
  /// In zh, this message translates to:
  /// **'修订订单 — 现场丈量后'**
  String get revisedTitle;

  /// No description provided for @revisedOrderNo.
  ///
  /// In zh, this message translates to:
  /// **'订单号'**
  String get revisedOrderNo;

  /// No description provided for @revisedPendingSync.
  ///
  /// In zh, this message translates to:
  /// **'待同步'**
  String get revisedPendingSync;

  /// No description provided for @revisedQuotedOn.
  ///
  /// In zh, this message translates to:
  /// **'报价日期'**
  String get revisedQuotedOn;

  /// No description provided for @revisedMeasuredOn.
  ///
  /// In zh, this message translates to:
  /// **'丈量日期'**
  String get revisedMeasuredOn;

  /// No description provided for @revisedColQuoted.
  ///
  /// In zh, this message translates to:
  /// **'报价尺寸'**
  String get revisedColQuoted;

  /// No description provided for @revisedColMeasured.
  ///
  /// In zh, this message translates to:
  /// **'实测尺寸'**
  String get revisedColMeasured;

  /// No description provided for @revisedColQuotedAmount.
  ///
  /// In zh, this message translates to:
  /// **'报价金额'**
  String get revisedColQuotedAmount;

  /// No description provided for @revisedColFinalAmount.
  ///
  /// In zh, this message translates to:
  /// **'最终金额'**
  String get revisedColFinalAmount;

  /// No description provided for @revisedColChange.
  ///
  /// In zh, this message translates to:
  /// **'差额'**
  String get revisedColChange;

  /// No description provided for @revisedEstimateTotal.
  ///
  /// In zh, this message translates to:
  /// **'报价总额'**
  String get revisedEstimateTotal;

  /// No description provided for @revisedFinalTotal.
  ///
  /// In zh, this message translates to:
  /// **'最终总额'**
  String get revisedFinalTotal;

  /// No description provided for @revisedYouSave.
  ///
  /// In zh, this message translates to:
  /// **'减少'**
  String get revisedYouSave;

  /// No description provided for @revisedNoChange.
  ///
  /// In zh, this message translates to:
  /// **'无变动'**
  String get revisedNoChange;

  /// No description provided for @revisedMinimumCharge.
  ///
  /// In zh, this message translates to:
  /// **'最低收费（订金 {amount}）'**
  String revisedMinimumCharge(String amount);

  /// No description provided for @revisedDepositPaid.
  ///
  /// In zh, this message translates to:
  /// **'已付订金'**
  String get revisedDepositPaid;

  /// No description provided for @revisedBalanceDue.
  ///
  /// In zh, this message translates to:
  /// **'应付余额'**
  String get revisedBalanceDue;

  /// No description provided for @revisedWhyTitle.
  ///
  /// In zh, this message translates to:
  /// **'为什么与报价单不同'**
  String get revisedWhyTitle;

  /// No description provided for @revisedWhyBody.
  ///
  /// In zh, this message translates to:
  /// **'报价单将每个尺寸进位到整数单位。本单据按现场实测尺寸计算，因此价格相同或更低。'**
  String get revisedWhyBody;

  /// No description provided for @revisedOverTitle.
  ///
  /// In zh, this message translates to:
  /// **'有窗口实测尺寸大于报价尺寸'**
  String get revisedOverTitle;

  /// No description provided for @revisedOverBody.
  ///
  /// In zh, this message translates to:
  /// **'以下尺寸在现场实测后大于报价时提供的尺寸，因此这些项目的金额较高。其余项目不变。请与我们核对。'**
  String get revisedOverBody;

  /// ONE placeholder on purpose. gen-l10n orders positional placeholders alphabetically, so a message with two or more has an argument order nobody chose -- it has already printed a height where a width belonged, on the one screen whose job is catching a wrong dimension. The room and product names are joined to this at the call site.
  ///
  /// In zh, this message translates to:
  /// **'比报价多 {amount}'**
  String revisedOverAmount(String amount);

  /// No description provided for @revisedPricedAt.
  ///
  /// In zh, this message translates to:
  /// **'按价目表版本 {version} 计价'**
  String revisedPricedAt(int version);

  /// No description provided for @revisedNotAnInvoice.
  ///
  /// In zh, this message translates to:
  /// **'本单据为修订订单确认书，非税务发票。'**
  String get revisedNotAnInvoice;

  /// No description provided for @revisedIncomplete.
  ///
  /// In zh, this message translates to:
  /// **'此订单尚不能打印 — {count, plural, =1{有 1 个项目尚未定价} other{有 {count} 个项目尚未定价}}。'**
  String revisedIncomplete(num count);

  /// No description provided for @revisedShare.
  ///
  /// In zh, this message translates to:
  /// **'分享修订订单'**
  String get revisedShare;

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

  /// No description provided for @orderConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'订单已确认'**
  String get orderConfirmed;

  /// No description provided for @orderNoPending.
  ///
  /// In zh, this message translates to:
  /// **'订单号等同步'**
  String get orderNoPending;

  /// No description provided for @orderPaidAndDue.
  ///
  /// In zh, this message translates to:
  /// **'已付 {paid}　尚欠 {balance}'**
  String orderPaidAndDue(String paid, String balance);

  /// No description provided for @orderDueNote.
  ///
  /// In zh, this message translates to:
  /// **'按估价算。量好之后只会一样或更少。'**
  String get orderDueNote;

  /// No description provided for @orderDepositTaken.
  ///
  /// In zh, this message translates to:
  /// **'已收订金 {amount}'**
  String orderDepositTaken(String amount);

  /// No description provided for @orderRateLocked.
  ///
  /// In zh, this message translates to:
  /// **'{category}促销价锁到 {date}'**
  String orderRateLocked(String category, String date);

  /// No description provided for @orderRateReference.
  ///
  /// In zh, this message translates to:
  /// **'按当时的价格表（第 {version} 版）算，账单以此为准。'**
  String orderRateReference(int version);

  /// No description provided for @orderMeasureNext.
  ///
  /// In zh, this message translates to:
  /// **'量好之后才出实际价钱。'**
  String get orderMeasureNext;

  /// No description provided for @statusConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'已确认'**
  String get statusConfirmed;

  /// No description provided for @statusMeasurementBooked.
  ///
  /// In zh, this message translates to:
  /// **'已约量尺'**
  String get statusMeasurementBooked;

  /// No description provided for @statusMeasured.
  ///
  /// In zh, this message translates to:
  /// **'已量尺'**
  String get statusMeasured;

  /// No description provided for @statusMaterialSelected.
  ///
  /// In zh, this message translates to:
  /// **'已选料'**
  String get statusMaterialSelected;

  /// No description provided for @statusInProduction.
  ///
  /// In zh, this message translates to:
  /// **'生产中'**
  String get statusInProduction;

  /// No description provided for @statusReady.
  ///
  /// In zh, this message translates to:
  /// **'待安装'**
  String get statusReady;

  /// No description provided for @statusInstalled.
  ///
  /// In zh, this message translates to:
  /// **'已安装'**
  String get statusInstalled;

  /// No description provided for @statusClosed.
  ///
  /// In zh, this message translates to:
  /// **'已结案'**
  String get statusClosed;

  /// No description provided for @statusCancelled.
  ///
  /// In zh, this message translates to:
  /// **'已取消'**
  String get statusCancelled;

  /// No description provided for @orderTitle.
  ///
  /// In zh, this message translates to:
  /// **'订单'**
  String get orderTitle;

  /// No description provided for @orderHistory.
  ///
  /// In zh, this message translates to:
  /// **'处理记录'**
  String get orderHistory;

  /// No description provided for @orderLines.
  ///
  /// In zh, this message translates to:
  /// **'订单内容'**
  String get orderLines;

  /// No description provided for @orderAdvanceTo.
  ///
  /// In zh, this message translates to:
  /// **'标记为{status}'**
  String orderAdvanceTo(String status);

  /// No description provided for @orderNothingLeft.
  ///
  /// In zh, this message translates to:
  /// **'这张订单已经没有下一步了。'**
  String get orderNothingLeft;

  /// No description provided for @orderCancelAction.
  ///
  /// In zh, this message translates to:
  /// **'取消这张订单'**
  String get orderCancelAction;

  /// No description provided for @orderCancelTitle.
  ///
  /// In zh, this message translates to:
  /// **'确定取消这张订单？'**
  String get orderCancelTitle;

  /// No description provided for @orderCancelReason.
  ///
  /// In zh, this message translates to:
  /// **'为什么取消？'**
  String get orderCancelReason;

  /// No description provided for @orderCancelHint.
  ///
  /// In zh, this message translates to:
  /// **'至少四个字。这就是记录。'**
  String get orderCancelHint;

  /// No description provided for @orderCancelConfirm.
  ///
  /// In zh, this message translates to:
  /// **'取消订单'**
  String get orderCancelConfirm;

  /// No description provided for @orderKeep.
  ///
  /// In zh, this message translates to:
  /// **'先不取消'**
  String get orderKeep;

  /// No description provided for @orderCancelDepositNote.
  ///
  /// In zh, this message translates to:
  /// **'订金照旧记录在案。退不退，另外处理。'**
  String get orderCancelDepositNote;

  /// No description provided for @orderEventBy.
  ///
  /// In zh, this message translates to:
  /// **'由{name}'**
  String orderEventBy(String name);

  /// No description provided for @orderRefusedNotATransition.
  ///
  /// In zh, this message translates to:
  /// **'这不是接下来的一步。'**
  String get orderRefusedNotATransition;

  /// No description provided for @orderRefusedTerminal.
  ///
  /// In zh, this message translates to:
  /// **'这张订单已经结束，不能再动。'**
  String get orderRefusedTerminal;

  /// No description provided for @orderRefusedLinesNotMeasured.
  ///
  /// In zh, this message translates to:
  /// **'还有窗口没量尺寸。'**
  String get orderRefusedLinesNotMeasured;

  /// No description provided for @orderRefusedMaterialNotChosen.
  ///
  /// In zh, this message translates to:
  /// **'还有项目没选料。'**
  String get orderRefusedMaterialNotChosen;

  /// No description provided for @orderRefusedBuyerDetails.
  ///
  /// In zh, this message translates to:
  /// **'这单超过 RM10,000。要先登记客户资料才能继续。'**
  String get orderRefusedBuyerDetails;

  /// No description provided for @orderRefusedNoReason.
  ///
  /// In zh, this message translates to:
  /// **'请先写理由，至少四个字。'**
  String get orderRefusedNoReason;

  /// No description provided for @buyerTitle.
  ///
  /// In zh, this message translates to:
  /// **'开发票所需的客户资料'**
  String get buyerTitle;

  /// No description provided for @buyerWhyOverThreshold.
  ///
  /// In zh, this message translates to:
  /// **'这单超过 {amount}。依法发票必须写客户本人的资料，不能开「现金销售」。'**
  String buyerWhyOverThreshold(String amount);

  /// No description provided for @buyerWhyNearThreshold.
  ///
  /// In zh, this message translates to:
  /// **'这单接近 {amount}。丈量后如果超过就一定要这些资料，那时客户已经回家了。现在就拿。'**
  String buyerWhyNearThreshold(String amount);

  /// No description provided for @buyerWhyRequested.
  ///
  /// In zh, this message translates to:
  /// **'客户要求电子发票，所以不论金额都需要这些资料。'**
  String get buyerWhyRequested;

  /// No description provided for @buyerStillNeeded.
  ///
  /// In zh, this message translates to:
  /// **'还缺'**
  String get buyerStillNeeded;

  /// No description provided for @buyerComplete.
  ///
  /// In zh, this message translates to:
  /// **'资料齐全了。'**
  String get buyerComplete;

  /// No description provided for @buyerMissingName.
  ///
  /// In zh, this message translates to:
  /// **'客户全名，与身份证或公司注册一致'**
  String get buyerMissingName;

  /// No description provided for @buyerMissingIdentifier.
  ///
  /// In zh, this message translates to:
  /// **'税号，或身份证件号码连同证件种类'**
  String get buyerMissingIdentifier;

  /// No description provided for @buyerMissingAddress.
  ///
  /// In zh, this message translates to:
  /// **'完整地址 — 街道、城市、州属、邮编'**
  String get buyerMissingAddress;

  /// No description provided for @buyerName.
  ///
  /// In zh, this message translates to:
  /// **'全名'**
  String get buyerName;

  /// No description provided for @buyerNameHint.
  ///
  /// In zh, this message translates to:
  /// **'照身份证或公司注册写，不要写花名'**
  String get buyerNameHint;

  /// No description provided for @buyerIdentifierSection.
  ///
  /// In zh, this message translates to:
  /// **'身份证明'**
  String get buyerIdentifierSection;

  /// No description provided for @buyerIdentifierNote.
  ///
  /// In zh, this message translates to:
  /// **'有税号就够。否则要填证件号码，并说明是哪一种 — 只有号码没有种类是不能报的。'**
  String get buyerIdentifierNote;

  /// No description provided for @buyerTin.
  ///
  /// In zh, this message translates to:
  /// **'税号 TIN'**
  String get buyerTin;

  /// No description provided for @buyerIdType.
  ///
  /// In zh, this message translates to:
  /// **'证件种类'**
  String get buyerIdType;

  /// No description provided for @buyerIdNumber.
  ///
  /// In zh, this message translates to:
  /// **'证件号码'**
  String get buyerIdNumber;

  /// No description provided for @buyerIdTypeNric.
  ///
  /// In zh, this message translates to:
  /// **'身份证 NRIC'**
  String get buyerIdTypeNric;

  /// No description provided for @buyerIdTypeBrn.
  ///
  /// In zh, this message translates to:
  /// **'公司注册 BRN'**
  String get buyerIdTypeBrn;

  /// No description provided for @buyerIdTypePassport.
  ///
  /// In zh, this message translates to:
  /// **'护照'**
  String get buyerIdTypePassport;

  /// No description provided for @buyerIdTypeArmy.
  ///
  /// In zh, this message translates to:
  /// **'军警证'**
  String get buyerIdTypeArmy;

  /// No description provided for @buyerAddressSection.
  ///
  /// In zh, this message translates to:
  /// **'地址'**
  String get buyerAddressSection;

  /// No description provided for @buyerAddress1.
  ///
  /// In zh, this message translates to:
  /// **'地址第一行'**
  String get buyerAddress1;

  /// No description provided for @buyerAddress2.
  ///
  /// In zh, this message translates to:
  /// **'地址第二行'**
  String get buyerAddress2;

  /// No description provided for @buyerCity.
  ///
  /// In zh, this message translates to:
  /// **'城市'**
  String get buyerCity;

  /// No description provided for @buyerState.
  ///
  /// In zh, this message translates to:
  /// **'州属'**
  String get buyerState;

  /// No description provided for @buyerPostcode.
  ///
  /// In zh, this message translates to:
  /// **'邮编'**
  String get buyerPostcode;

  /// No description provided for @buyerMsic.
  ///
  /// In zh, this message translates to:
  /// **'MSIC 代码'**
  String get buyerMsic;

  /// No description provided for @buyerMsicNote.
  ///
  /// In zh, this message translates to:
  /// **'只有公司客户需要。个人客户留空。'**
  String get buyerMsicNote;

  /// No description provided for @buyerRequested.
  ///
  /// In zh, this message translates to:
  /// **'客户要求电子发票'**
  String get buyerRequested;

  /// No description provided for @buyerSave.
  ///
  /// In zh, this message translates to:
  /// **'保存资料'**
  String get buyerSave;

  /// No description provided for @buyerSaved.
  ///
  /// In zh, this message translates to:
  /// **'资料已保存'**
  String get buyerSaved;

  /// No description provided for @buyerEdit.
  ///
  /// In zh, this message translates to:
  /// **'客户资料'**
  String get buyerEdit;

  /// No description provided for @buyerNotAnInvoice.
  ///
  /// In zh, this message translates to:
  /// **'收集这些是为了在会计系统开发票。本应用不开发票。'**
  String get buyerNotAnInvoice;

  /// No description provided for @overrideTitle.
  ///
  /// In zh, this message translates to:
  /// **'改这个价钱'**
  String get overrideTitle;

  /// No description provided for @overrideCurrent.
  ///
  /// In zh, this message translates to:
  /// **'现在是{amount}'**
  String overrideCurrent(String amount);

  /// No description provided for @overrideNewTotal.
  ///
  /// In zh, this message translates to:
  /// **'新的小计'**
  String get overrideNewTotal;

  /// No description provided for @overrideReason.
  ///
  /// In zh, this message translates to:
  /// **'为什么改？'**
  String get overrideReason;

  /// No description provided for @overrideHint.
  ///
  /// In zh, this message translates to:
  /// **'至少四个字。每次改动都会记在你名下。'**
  String get overrideHint;

  /// No description provided for @overrideApply.
  ///
  /// In zh, this message translates to:
  /// **'改'**
  String get overrideApply;

  /// No description provided for @overrideMarker.
  ///
  /// In zh, this message translates to:
  /// **'价钱经人手调整'**
  String get overrideMarker;

  /// No description provided for @overrideRefusedNotAnAdmin.
  ///
  /// In zh, this message translates to:
  /// **'只有管理员可以改价钱。'**
  String get overrideRefusedNotAnAdmin;

  /// No description provided for @overrideRefusedNoReason.
  ///
  /// In zh, this message translates to:
  /// **'请先写理由，至少四个字。'**
  String get overrideRefusedNoReason;

  /// No description provided for @overrideRefusedNegativeTotal.
  ///
  /// In zh, this message translates to:
  /// **'一个项目不能低过零。'**
  String get overrideRefusedNegativeTotal;

  /// No description provided for @overrideRefusedNoChange.
  ///
  /// In zh, this message translates to:
  /// **'本来就是这个价钱。'**
  String get overrideRefusedNoChange;

  /// No description provided for @overrideRefusedOrderFinished.
  ///
  /// In zh, this message translates to:
  /// **'这张订单已经结束，价钱不能再动。'**
  String get overrideRefusedOrderFinished;

  /// No description provided for @overridesThisWeek.
  ///
  /// In zh, this message translates to:
  /// **'这个星期改过的价钱'**
  String get overridesThisWeek;

  /// No description provided for @overridesNone.
  ///
  /// In zh, this message translates to:
  /// **'这个星期没有人改过价钱。'**
  String get overridesNone;

  /// No description provided for @overrideRow.
  ///
  /// In zh, this message translates to:
  /// **'{before} 改成 {after}，{name}'**
  String overrideRow(String before, String after, String name);

  /// No description provided for @declinesTitle.
  ///
  /// In zh, this message translates to:
  /// **'问过的订金'**
  String get declinesTitle;

  /// No description provided for @declinesNone.
  ///
  /// In zh, this message translates to:
  /// **'这段时间没有人被问过订金。'**
  String get declinesNone;

  /// No description provided for @declinesAsked.
  ///
  /// In zh, this message translates to:
  /// **'问了 {count} 次'**
  String declinesAsked(int count);

  /// No description provided for @declinesTook.
  ///
  /// In zh, this message translates to:
  /// **'收到 {count} 单'**
  String declinesTook(int count);

  /// No description provided for @declinesSaidNo.
  ///
  /// In zh, this message translates to:
  /// **'{count} 单说不要'**
  String declinesSaidNo(int count);

  /// No description provided for @declinesDismissed.
  ///
  /// In zh, this message translates to:
  /// **'{count} 单没答复'**
  String declinesDismissed(int count);

  /// No description provided for @declinesRemoved.
  ///
  /// In zh, this message translates to:
  /// **'{count} 单把项目删掉'**
  String declinesRemoved(int count);

  /// No description provided for @declinesLeftOnTable.
  ///
  /// In zh, this message translates to:
  /// **'报了 {amount}，没收订金'**
  String declinesLeftOnTable(String amount);

  /// No description provided for @declinesTakeRate.
  ///
  /// In zh, this message translates to:
  /// **'有答复的当中 {percent}% 付了钱'**
  String declinesTakeRate(int percent);
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
