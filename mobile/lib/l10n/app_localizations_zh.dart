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
}
