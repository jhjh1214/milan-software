// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class LZh extends L {
  LZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => '米兰报价';

  @override
  String get languageChinese => '中文';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageMalay => 'Bahasa Melayu';

  @override
  String get language => '语言';

  @override
  String get quoteTitle => '报价';

  @override
  String get newQuote => '新报价';

  @override
  String get addWindow => '加窗口';

  @override
  String get emptyQuoteTitle => '还没有窗口';

  @override
  String get emptyQuoteAction => '按下面的按钮加第一个窗口';

  @override
  String get stepRoom => '哪个房间？';

  @override
  String get stepProduct => '什么产品？';

  @override
  String get stepMaterial => '什么料？';

  @override
  String get stepSizes => '尺寸';

  @override
  String get stepUpgrade => '要加什么吗？';

  @override
  String get upgradeNone => '不用，就这样';

  @override
  String get upgradeIncluded => '普通轨道已包在价格里，以下是升级选项';

  @override
  String upgradeAdded(String name) {
    return '已加 $name';
  }

  @override
  String upgradeOf(String parent) {
    return '配 $parent';
  }

  @override
  String get stepFamily => '哪一类？';

  @override
  String get familyCurtain => '窗帘';

  @override
  String get familyBlind => '百叶 / 卷帘';

  @override
  String get familyTrack => '轨道 / 杆';

  @override
  String get familyFlooring => '地板';

  @override
  String get familyWallpaper => '壁纸';

  @override
  String get familyAddon => '配件';

  @override
  String get familyService => '服务';

  @override
  String get materialLater => '料丈量时再选';

  @override
  String get materialLaterNote => '报价按最贵的料算，选了较便宜的会更低。';

  @override
  String stepProgress(int current, int total, String room) {
    return '第 $current 个，共 $total 个 · $room';
  }

  @override
  String get roomLiving => '客厅';

  @override
  String get roomMaster => '主人房';

  @override
  String get roomBedroom => '房间';

  @override
  String get roomKitchen => '厨房';

  @override
  String get roomBalcony => '阳台';

  @override
  String get roomStudy => '书房';

  @override
  String get roomOther => '其他';

  @override
  String get roomCustom => '自己填';

  @override
  String get width => '宽';

  @override
  String get height => '高';

  @override
  String get quantity => '数量';

  @override
  String sameWindows(int count) {
    return '$count 个一样的窗口';
  }

  @override
  String get unitFoot => '尺';

  @override
  String get unitInch => '寸';

  @override
  String get unitMm => '毫米';

  @override
  String get unitCm => '厘米';

  @override
  String get unitMetre => '米';

  @override
  String get unitSqft => '平方尺';

  @override
  String billedAs(String qty, String unit) {
    return '按 $qty $unit计';
  }

  @override
  String enteredAs(String value) {
    return '输入 $value';
  }

  @override
  String minQtyApplied(String qty, String unit) {
    return '最低 $qty $unit';
  }

  @override
  String get errorInvalidDimension => '看不懂这个尺寸';

  @override
  String get errorDimensionRequired => '请填尺寸';

  @override
  String get errorNoRate => '这个产品的价格资料不齐全，请通知公司';

  @override
  String warnUnitLooksWrong(
    String value,
    String unit,
    String converted,
    String suggestion,
  ) {
    return '$value $unit = $converted，是不是要打 $suggestion？';
  }

  @override
  String warnSwitchTo(String unit) {
    return '改成 $unit';
  }

  @override
  String warnDropVeryShort(String value) {
    return '高度只有 $value，确认吗？';
  }

  @override
  String warnNearBandEdge(String edge) {
    return '刚刚超过 $edge，请确认尺寸';
  }

  @override
  String warnBandBothPrices(String lower, String lowerPrice, String upper) {
    return '$lower 以内 $lowerPrice · 超过 $upper';
  }

  @override
  String get runningTotal => '总额';

  @override
  String get customerTitle => '客户资料';

  @override
  String get customerName => '客户姓名';

  @override
  String get customerPhone => '电话';

  @override
  String get customerOptional => '可以不填，之后再补';

  @override
  String get deliveryTitle => '送货地区';

  @override
  String get deliveryNone => '马六甲市区（不加钱）';

  @override
  String deliveryCharge(String area) {
    return '路费 $area';
  }

  @override
  String get deliveryAskEarly => '先问地区，免得报了价才加钱';

  @override
  String get save => '保存';

  @override
  String get ratesTitle => '价格表';

  @override
  String get ratesEditOne => '改单项价格';

  @override
  String get ratesSearch => '搜索产品';

  @override
  String get ratesNewRate => '新价格 (RM)';

  @override
  String get ratesNewMvp => 'MVP 价格 (RM)';

  @override
  String ratesCurrent(String rate) {
    return '现价 $rate';
  }

  @override
  String get ratesInvalid => '价格填错了';

  @override
  String get ratesMvpTooHigh => 'MVP 价不可以高过普通价';

  @override
  String get ratesNoMatch => '找不到产品';

  @override
  String ratesVersion(int version, int count) {
    return '版本 $version · $count 项';
  }

  @override
  String get ratesExport => '导出 Excel 档';

  @override
  String get ratesImport => '导入改好的档';

  @override
  String get ratesNoChanges => '没有价格改动';

  @override
  String ratesReview(int count) {
    return '$count 项价格有改动，确认后才生效';
  }

  @override
  String get ratesApply => '确认更新价格';

  @override
  String ratesApplied(int version) {
    return '价格已更新到版本 $version';
  }

  @override
  String get ratesErrors => '档案有问题，未更新任何价格';

  @override
  String get ratesRestore => '还原原本价格表';

  @override
  String ratesCustom(int version) {
    return '价格表已被修改（版本 $version）';
  }

  @override
  String get share => '分享报价';

  @override
  String get pdfTitle => '报价单';

  @override
  String get pdfCompany => '米兰窗帘地板';

  @override
  String get pdfQuoteNo => '报价编号';

  @override
  String get pdfDate => '日期';

  @override
  String get pdfRoom => '房间';

  @override
  String get pdfProduct => '产品';

  @override
  String get pdfSize => '尺寸';

  @override
  String get pdfBilled => '计算';

  @override
  String get pdfRate => '单价';

  @override
  String get pdfAmount => '金额';

  @override
  String get pdfNotAnInvoice => '此单不是税务发票，只是报价参考。';

  @override
  String pdfValidity(int days) {
    return '报价有效期 $days 天';
  }

  @override
  String pdfPage(int page, int total) {
    return '第 $page 页，共 $total 页';
  }

  @override
  String get subtotal => '小计';

  @override
  String get lineTotal => '小计';

  @override
  String depositFloorRow(String amount) {
    return '最低报价（订金 $amount）';
  }

  @override
  String get depositFloorExplain => '报价不会低过订金，免得订金比货还贵。';

  @override
  String get disclaimerTitle => '参考价';

  @override
  String get disclaimerBody => '此报价按整数进位计算，仅供参考。现场实际丈量后，价格只会相同或更低，不会更高。';

  @override
  String get provisionalCardBanner => '价格表还没确认，不可以给客户报价';

  @override
  String listFair(String code) {
    return '展会价 $code';
  }

  @override
  String get listStandard => '平时价（非展会）';

  @override
  String get listStandardProvisional =>
      '平时价暂定：窗帘加 20%，百叶加 50%。其他（轨道、地板、壁纸、配件）全年同价。';

  @override
  String expiredCardBanner(String code, String date) {
    return '这是 $code 展会价，$date 已过期。日常报价不可以用。';
  }

  @override
  String get delete => '删除';

  @override
  String get deleted => '已删除';

  @override
  String get undo => '还原';

  @override
  String get back => '返回';

  @override
  String get next => '下一步';

  @override
  String get done => '完成';

  @override
  String get cancel => '取消';

  @override
  String get confirm => '确认';

  @override
  String get keypadClear => '清除';

  @override
  String get keypadBackspace => '退格';

  @override
  String get keypadDone => '好';

  @override
  String get bandLower => '10 尺以内';

  @override
  String get bandUpper => '超过 10 尺';

  @override
  String get tierMvp => 'MVP 会员价';

  @override
  String get tierStandard => '普通价';

  @override
  String get roleAdmin => '管理员';

  @override
  String get roleStaff => '员工';

  @override
  String get roleParttime => '临时员工';

  @override
  String get syncTitle => '同步';

  @override
  String get signInTitle => '登入';

  @override
  String get signInPhone => '手机号码';

  @override
  String get signInPin => '密码 PIN';

  @override
  String get signInAction => '登入';

  @override
  String get signInFailed => '号码或密码不对';

  @override
  String get signInOffline => '没有网络。有信号时再试。';

  @override
  String signInBusy(int seconds) {
    return '试太多次了。请等 $seconds 秒。';
  }

  @override
  String get signInWhy => '出展前登入一次就好。之后没有网络也照样用。';

  @override
  String signedInAs(String name, String role) {
    return '已登入：$name（$role）';
  }

  @override
  String get signOut => '登出';

  @override
  String get notSignedIn => '还没登入。报价照常，只是不会传回公司。';

  @override
  String get serverAddress => '服务器地址';

  @override
  String get serverAddressInvalid => '请输入 https 地址，例如 milan.example.com';

  @override
  String get serverAddressChanged => '服务器已更改，请重新登入。';

  @override
  String get syncNow => '立即同步';

  @override
  String get syncRunning => '同步中';

  @override
  String get syncNever => '还没同步过';

  @override
  String syncLastAt(String time) {
    return '上次同步：$time';
  }

  @override
  String get syncOffline => '没有网络。一切照常，稍后自动补上。';

  @override
  String get syncSignedOut => '这台手机已被登出。请重新登入才能上传报价。';

  @override
  String syncPricesUpdated(int version) {
    return '价格已更新到第 $version 版';
  }

  @override
  String get syncPricesCurrent => '价格已是最新';

  @override
  String syncQueued(int count) {
    return '有 $count 张报价等着上传';
  }

  @override
  String syncSent(int count) {
    return '已上传 $count 张报价';
  }

  @override
  String syncParked(int count) {
    return '有 $count 张报价需要处理';
  }

  @override
  String syncDisagreed(int count) {
    return '有 $count 张报价公司算出的价格不一样。订单照收，已标记待查。';
  }

  @override
  String get syncLocalEditDropped => '这台手机改过的价格已被公司的价格表取代。';

  @override
  String pricesFromServer(String time) {
    return '价格来自公司，$time 更新';
  }

  @override
  String get pricesBundled => '这是随程序附带的价格。登入后会取得公司的价格表。';

  @override
  String get pricesLocal => '这是在这台手机上改过的价格，下次同步会被取代。';

  @override
  String get ratesServerOwned => '价格由公司统一发布，每台手机报价一致。在这里的更改会发布给所有人。';

  @override
  String get ratesPublish => '发布给所有人';

  @override
  String ratesPublished(int version) {
    return '已发布第 $version 版。每台手机下次同步就会收到。';
  }

  @override
  String get ratesPublishOffline => '发布需要网络，这样每台手机才拿到同一份价格表。';

  @override
  String get ratesReadOnly => '只有公司可以更改价格。';

  @override
  String get ratesCheckUpdates => '检查更新';

  @override
  String get fairModeTitle => '展销模式';

  @override
  String get fairModePrepare => '出展前准备';

  @override
  String get fairModeWhy => '下载两份价格表并清空上传队列，手机就能连续几天没网络也照用。';

  @override
  String get fairModeReady => '准备好了。两份价格表都是最新，也没有待上传的报价。';

  @override
  String get fairModeNotReady => '还没准备好。出发前请连上网络再试一次。';

  @override
  String get atFair => '在展销会';

  @override
  String get atFairHelp => '用促销价，RM300 可以锁价 12 个月。展销会结束后会自动关掉。';

  @override
  String atFairEnded(String date) {
    return '展销会已在 $date 结束，现在是平时价。';
  }

  @override
  String get channelFair => '展销会';

  @override
  String get channelShowroom => '店里';

  @override
  String depositNeededTitle(String category) {
    return '这单有$category';
  }

  @override
  String depositNeededBody(String category, String amount) {
    return '$category要另外 $amount，才可以锁住促销价 12 个月。';
  }

  @override
  String depositCollect(String amount) {
    return '收 $amount';
  }

  @override
  String get depositDecline => '不锁价，照今天的价';

  @override
  String depositRemove(String category) {
    return '取消$category';
  }

  @override
  String depositCollected(String amount, String category, String date) {
    return '已记录 $amount。$category价格锁到 $date。';
  }

  @override
  String depositDeclined(String category) {
    return '知道了。$category没有锁价。';
  }

  @override
  String get depositNotAtFair => '只有在展销会付的 RM300 才能锁价。';

  @override
  String get categoryCurtain => '窗帘';

  @override
  String get categoryFlooring => '地板';

  @override
  String get categoryWallpaper => '壁纸';

  @override
  String get paymentMethodTitle => '怎么付？';

  @override
  String get methodCash => '现金';

  @override
  String get methodCard => '刷卡';

  @override
  String get methodDuitnow => 'DuitNow';

  @override
  String get methodTransfer => '银行转账';

  @override
  String get methodCheque => '支票';

  @override
  String get receiptPending => '收据号码等同步';

  @override
  String paymentsTaken(String amount) {
    return '已收 $amount';
  }

  @override
  String get cashUpTitle => '今天收的钱';

  @override
  String get cashUpExpected => '应该有';

  @override
  String get cashUpCounted => '实际点到';

  @override
  String get cashUpShort => '少了';

  @override
  String get cashUpOver => '多了';

  @override
  String get cashUpBalanced => '对得上，没问题。';

  @override
  String get cashUpNothingTaken => '今天还没收到钱。';

  @override
  String cashUpNotCounted(int count) {
    return '还有 $count 项现金没点。点了才算数。';
  }

  @override
  String cashUpOff(String method, String amount, String direction) {
    return '$method$direction $amount。';
  }

  @override
  String get orderConfirmed => '订单已确认';

  @override
  String get orderNoPending => '订单号等同步';

  @override
  String orderPaidAndDue(String paid, String balance) {
    return '已付 $paid　尚欠 $balance';
  }

  @override
  String get orderDueNote => '按估价算。量好之后只会一样或更少。';

  @override
  String orderDepositTaken(String amount) {
    return '已收订金 $amount';
  }

  @override
  String orderRateLocked(String category, String date) {
    return '$category促销价锁到 $date';
  }

  @override
  String orderRateReference(int version) {
    return '按当时的价格表（第 $version 版）算，账单以此为准。';
  }

  @override
  String get orderMeasureNext => '量好之后才出实际价钱。';

  @override
  String get statusConfirmed => '已确认';

  @override
  String get statusMeasurementBooked => '已约量尺';

  @override
  String get statusMeasured => '已量尺';

  @override
  String get statusMaterialSelected => '已选料';

  @override
  String get statusInProduction => '生产中';

  @override
  String get statusReady => '待安装';

  @override
  String get statusInstalled => '已安装';

  @override
  String get statusClosed => '已结案';

  @override
  String get statusCancelled => '已取消';

  @override
  String get orderTitle => '订单';

  @override
  String get orderHistory => '处理记录';

  @override
  String get orderLines => '订单内容';

  @override
  String orderAdvanceTo(String status) {
    return '标记为$status';
  }

  @override
  String get orderNothingLeft => '这张订单已经没有下一步了。';

  @override
  String get orderCancelAction => '取消这张订单';

  @override
  String get orderCancelTitle => '确定取消这张订单？';

  @override
  String get orderCancelReason => '为什么取消？';

  @override
  String get orderCancelHint => '至少四个字。这就是记录。';

  @override
  String get orderCancelConfirm => '取消订单';

  @override
  String get orderKeep => '先不取消';

  @override
  String get orderCancelDepositNote => '订金照旧记录在案。退不退，另外处理。';

  @override
  String orderEventBy(String name) {
    return '由$name';
  }

  @override
  String get orderRefusedNotATransition => '这不是接下来的一步。';

  @override
  String get orderRefusedTerminal => '这张订单已经结束，不能再动。';

  @override
  String get orderRefusedLinesNotMeasured => '还有窗口没量尺寸。';

  @override
  String get orderRefusedMaterialNotChosen => '还有项目没选料。';

  @override
  String get orderRefusedNoReason => '请先写理由，至少四个字。';

  @override
  String get overrideTitle => '改这个价钱';

  @override
  String overrideCurrent(String amount) {
    return '现在是$amount';
  }

  @override
  String get overrideNewTotal => '新的小计';

  @override
  String get overrideReason => '为什么改？';

  @override
  String get overrideHint => '至少四个字。每次改动都会记在你名下。';

  @override
  String get overrideApply => '改';

  @override
  String get overrideMarker => '价钱经人手调整';

  @override
  String get overrideRefusedNotAnAdmin => '只有管理员可以改价钱。';

  @override
  String get overrideRefusedNoReason => '请先写理由，至少四个字。';

  @override
  String get overrideRefusedNegativeTotal => '一个项目不能低过零。';

  @override
  String get overrideRefusedNoChange => '本来就是这个价钱。';

  @override
  String get overrideRefusedOrderFinished => '这张订单已经结束，价钱不能再动。';

  @override
  String get overridesThisWeek => '这个星期改过的价钱';

  @override
  String get overridesNone => '这个星期没有人改过价钱。';

  @override
  String overrideRow(String before, String after, String name) {
    return '$before 改成 $after，$name';
  }

  @override
  String get declinesTitle => '问过的订金';

  @override
  String get declinesNone => '这段时间没有人被问过订金。';

  @override
  String declinesAsked(int count) {
    return '问了 $count 次';
  }

  @override
  String declinesTook(int count) {
    return '收到 $count 单';
  }

  @override
  String declinesSaidNo(int count) {
    return '$count 单说不要';
  }

  @override
  String declinesDismissed(int count) {
    return '$count 单没答复';
  }

  @override
  String declinesRemoved(int count) {
    return '$count 单把项目删掉';
  }

  @override
  String declinesLeftOnTable(String amount) {
    return '报了 $amount，没收订金';
  }

  @override
  String declinesTakeRate(int percent) {
    return '有答复的当中 $percent% 付了钱';
  }
}
