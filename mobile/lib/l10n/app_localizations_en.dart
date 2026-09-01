// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class LEn extends L {
  LEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Milan Quote';

  @override
  String get languageChinese => '中文';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageMalay => 'Bahasa Melayu';

  @override
  String get language => 'Language';

  @override
  String get quoteTitle => 'Quotation';

  @override
  String get newQuote => 'New quotation';

  @override
  String get addWindow => 'Add window';

  @override
  String get emptyQuoteTitle => 'No windows yet';

  @override
  String get emptyQuoteAction => 'Tap below to add the first window';

  @override
  String get stepRoom => 'Which room?';

  @override
  String get stepProduct => 'Which product?';

  @override
  String get stepMaterial => 'Which material?';

  @override
  String get stepSizes => 'Sizes';

  @override
  String get stepUpgrade => 'Add anything?';

  @override
  String get upgradeNone => 'No, that is all';

  @override
  String get upgradeIncluded =>
      'A normal track is already included. These are upgrades.';

  @override
  String upgradeAdded(String name) {
    return 'Added $name';
  }

  @override
  String upgradeOf(String parent) {
    return 'with $parent';
  }

  @override
  String get stepFamily => 'Which category?';

  @override
  String get familyCurtain => 'Curtains';

  @override
  String get familyBlind => 'Blinds';

  @override
  String get familyTrack => 'Tracks & rods';

  @override
  String get familyFlooring => 'Flooring';

  @override
  String get familyWallpaper => 'Wallpaper';

  @override
  String get familyAddon => 'Add-ons';

  @override
  String get familyService => 'Services';

  @override
  String get materialLater => 'Material chosen at measurement';

  @override
  String get materialLaterNote =>
      'Quoted at the dearest material. A cheaper choice lowers this.';

  @override
  String stepProgress(int current, int total, String room) {
    return 'Window $current of $total · $room';
  }

  @override
  String get roomLiving => 'Living room';

  @override
  String get roomMaster => 'Master bedroom';

  @override
  String get roomBedroom => 'Bedroom';

  @override
  String get roomKitchen => 'Kitchen';

  @override
  String get roomBalcony => 'Balcony';

  @override
  String get roomStudy => 'Study';

  @override
  String get roomOther => 'Other';

  @override
  String get roomCustom => 'Type a name';

  @override
  String get width => 'Width';

  @override
  String get height => 'Height';

  @override
  String get quantity => 'Quantity';

  @override
  String sameWindows(int count) {
    return '$count identical windows';
  }

  @override
  String get unitFoot => 'ft';

  @override
  String get unitInch => 'in';

  @override
  String get unitMm => 'mm';

  @override
  String get unitCm => 'cm';

  @override
  String get unitMetre => 'm';

  @override
  String get unitSqft => 'sqft';

  @override
  String billedAs(String qty, String unit) {
    return 'billed as $qty $unit';
  }

  @override
  String enteredAs(String value) {
    return 'entered $value';
  }

  @override
  String minQtyApplied(String qty, String unit) {
    return 'minimum $qty $unit';
  }

  @override
  String get errorInvalidDimension => 'That size cannot be read';

  @override
  String get errorDimensionRequired => 'Enter a size';

  @override
  String get errorNoRate =>
      'This product has no complete rate. Tell the office.';

  @override
  String warnUnitLooksWrong(
    String value,
    String unit,
    String converted,
    String suggestion,
  ) {
    return '$value $unit = $converted. Did you mean $suggestion?';
  }

  @override
  String warnSwitchTo(String unit) {
    return 'Change to $unit';
  }

  @override
  String warnDropVeryShort(String value) {
    return 'Height is only $value. Is that right?';
  }

  @override
  String warnNearBandEdge(String edge) {
    return 'Just over $edge. Please check the size.';
  }

  @override
  String warnBandBothPrices(String lower, String lowerPrice, String upper) {
    return 'Up to $lower: $lowerPrice · Over $upper';
  }

  @override
  String get runningTotal => 'Total';

  @override
  String get customerTitle => 'Customer';

  @override
  String get customerName => 'Customer name';

  @override
  String get customerPhone => 'Phone';

  @override
  String get customerOptional => 'Optional — can be filled in later';

  @override
  String get deliveryTitle => 'Delivery area';

  @override
  String get deliveryNone => 'Melaka town (no charge)';

  @override
  String deliveryCharge(String area) {
    return 'Travel $area';
  }

  @override
  String get deliveryAskEarly => 'Asked before the total, never after';

  @override
  String get save => 'Save';

  @override
  String get share => 'Share quotation';

  @override
  String get pdfTitle => 'Quotation';

  @override
  String get pdfCompany => 'Milan Curtain & Flooring';

  @override
  String get pdfQuoteNo => 'Quotation no.';

  @override
  String get pdfDate => 'Date';

  @override
  String get pdfRoom => 'Room';

  @override
  String get pdfProduct => 'Product';

  @override
  String get pdfSize => 'Size';

  @override
  String get pdfBilled => 'Billed';

  @override
  String get pdfRate => 'Rate';

  @override
  String get pdfAmount => 'Amount';

  @override
  String get pdfNotAnInvoice =>
      'This document is a quotation, not a tax invoice.';

  @override
  String pdfValidity(int days) {
    return 'Valid for $days days';
  }

  @override
  String pdfPage(int page, int total) {
    return 'Page $page of $total';
  }

  @override
  String get subtotal => 'Subtotal';

  @override
  String get lineTotal => 'Line total';

  @override
  String depositFloorRow(String amount) {
    return 'Minimum quotation (deposit $amount)';
  }

  @override
  String get depositFloorExplain =>
      'A quotation is never less than the deposit, so the deposit can never exceed the order.';

  @override
  String get disclaimerTitle => 'Reference price';

  @override
  String get disclaimerBody =>
      'This quotation is rounded up to whole units and is for reference only. After on-site measurement the final price will be the same or lower, never higher.';

  @override
  String get provisionalCardBanner =>
      'Rate card not confirmed. Do not quote a customer.';

  @override
  String expiredCardBanner(String code, String date) {
    return 'These are $code fair rates and they expired on $date. Not valid for everyday quoting.';
  }

  @override
  String get delete => 'Delete';

  @override
  String get deleted => 'Deleted';

  @override
  String get undo => 'Undo';

  @override
  String get back => 'Back';

  @override
  String get next => 'Next';

  @override
  String get done => 'Done';

  @override
  String get cancel => 'Cancel';

  @override
  String get confirm => 'Confirm';

  @override
  String get keypadClear => 'Clear';

  @override
  String get keypadBackspace => 'Backspace';

  @override
  String get keypadDone => 'OK';

  @override
  String get bandLower => 'Up to 10ft';

  @override
  String get bandUpper => 'Over 10ft';

  @override
  String get tierMvp => 'MVP rate';

  @override
  String get tierStandard => 'Standard rate';
}
