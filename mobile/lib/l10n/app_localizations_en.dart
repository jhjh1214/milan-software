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
  String get ratesTitle => 'Price list';

  @override
  String get ratesEditOne => 'Change one price';

  @override
  String get ratesSearch => 'Search products';

  @override
  String get ratesNewRate => 'New rate (RM)';

  @override
  String get ratesNewMvp => 'MVP rate (RM)';

  @override
  String ratesCurrent(String rate) {
    return 'Now $rate';
  }

  @override
  String get ratesInvalid => 'That is not a price';

  @override
  String get ratesMvpTooHigh =>
      'The MVP rate cannot be above the standard rate';

  @override
  String get ratesNoMatch => 'No product found';

  @override
  String ratesVersion(int version, int count) {
    return 'Version $version · $count products';
  }

  @override
  String get ratesExport => 'Export for Excel';

  @override
  String get ratesImport => 'Import edited file';

  @override
  String get ratesNoChanges => 'No price changes';

  @override
  String ratesReview(int count) {
    return '$count prices would change. Nothing is applied until you confirm.';
  }

  @override
  String get ratesApply => 'Apply these prices';

  @override
  String ratesApplied(int version) {
    return 'Prices updated to version $version';
  }

  @override
  String get ratesErrors => 'The file has problems. No prices were changed.';

  @override
  String get ratesRestore => 'Restore the original price list';

  @override
  String ratesCustom(int version) {
    return 'Price list has been edited (version $version)';
  }

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
  String listFair(String code) {
    return 'Fair prices $code';
  }

  @override
  String get listStandard => 'Standard prices (not a fair)';

  @override
  String get listStandardProvisional =>
      'Standard prices are provisional: curtains +20%, blinds +50%. Everything else costs the same all year.';

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

  @override
  String get roleAdmin => 'Admin';

  @override
  String get roleStaff => 'Staff';

  @override
  String get roleParttime => 'Part-timer';

  @override
  String get syncTitle => 'Sync';

  @override
  String get signInTitle => 'Sign in';

  @override
  String get signInPhone => 'Phone number';

  @override
  String get signInPin => 'PIN';

  @override
  String get signInAction => 'Sign in';

  @override
  String get signInFailed => 'Phone or PIN is wrong';

  @override
  String get signInOffline => 'No connection. Try again when you have signal.';

  @override
  String signInBusy(int seconds) {
    return 'Too many tries. Wait $seconds seconds.';
  }

  @override
  String get signInWhy =>
      'Sign in once before the fair. The app keeps working offline afterwards.';

  @override
  String signedInAs(String name, String role) {
    return 'Signed in as $name ($role)';
  }

  @override
  String get signOut => 'Sign out';

  @override
  String get notSignedIn =>
      'Not signed in. Quoting still works; nothing is sent to the office.';

  @override
  String get serverAddress => 'Server address';

  @override
  String get serverAddressInvalid =>
      'Enter an https address, for example milan.example.com';

  @override
  String get serverAddressChanged => 'Server changed. Sign in again.';

  @override
  String get syncNow => 'Sync now';

  @override
  String get syncRunning => 'Syncing';

  @override
  String get syncNever => 'Not synced yet';

  @override
  String syncLastAt(String time) {
    return 'Last synced $time';
  }

  @override
  String get syncOffline =>
      'No connection. Everything still works; this will catch up later.';

  @override
  String get syncSignedOut =>
      'This handset was signed out. Sign in again to send quotes.';

  @override
  String syncPricesUpdated(int version) {
    return 'Prices updated to version $version';
  }

  @override
  String get syncPricesCurrent => 'Prices are up to date';

  @override
  String syncQueued(int count) {
    return '$count quotes waiting to send';
  }

  @override
  String syncSent(int count) {
    return '$count quotes sent';
  }

  @override
  String syncParked(int count) {
    return '$count quotes need attention';
  }

  @override
  String syncDisagreed(int count) {
    return '$count quotes were priced differently by the office. They were accepted and flagged for review.';
  }

  @override
  String get syncLocalEditDropped =>
      'The prices edited on this phone were replaced by the office list.';

  @override
  String pricesFromServer(String time) {
    return 'Prices from the office, as of $time';
  }

  @override
  String get pricesBundled =>
      'Prices as shipped with the app. Sign in to get the office list.';

  @override
  String get pricesLocal =>
      'Prices edited on this phone. They will be replaced on the next sync.';

  @override
  String get ratesServerOwned =>
      'Prices come from the office so every handset quotes the same. A change made here is published to everyone.';

  @override
  String get ratesPublish => 'Publish to everyone';

  @override
  String ratesPublished(int version) {
    return 'Published version $version. Every handset picks it up on its next sync.';
  }

  @override
  String get ratesPublishOffline =>
      'Publishing needs a connection, so that every handset gets the same list.';

  @override
  String get ratesReadOnly => 'Only the office can change prices.';

  @override
  String get ratesCheckUpdates => 'Check for updates';

  @override
  String get fairModeTitle => 'Fair mode';

  @override
  String get fairModePrepare => 'Get ready for a fair';

  @override
  String get fairModeWhy =>
      'Downloads both price lists and empties the queue, so the phone works for days with no signal.';

  @override
  String get fairModeReady =>
      'Ready. Both price lists are current and nothing is waiting to send.';

  @override
  String get fairModeNotReady =>
      'Not ready yet. Connect and try again before you leave.';

  @override
  String get atFair => 'At a fair';

  @override
  String get atFairHelp =>
      'Fair prices, and RM300 holds them for 12 months. Turns itself off when the fair ends.';

  @override
  String atFairEnded(String date) {
    return 'The fair ended on $date. These are standard prices.';
  }

  @override
  String get channelFair => 'Fair';

  @override
  String get channelShowroom => 'Showroom';

  @override
  String depositNeededTitle(String category) {
    return 'This order has $category';
  }

  @override
  String depositNeededBody(String category, String amount) {
    return '$category needs its own $amount to hold the promo price for 12 months.';
  }

  @override
  String depositCollect(String amount) {
    return 'Take $amount';
  }

  @override
  String get depositDecline => 'No hold, today\'s price';

  @override
  String depositRemove(String category) {
    return 'Remove $category';
  }

  @override
  String depositCollected(String amount, String category, String date) {
    return '$amount recorded. $category held until $date.';
  }

  @override
  String depositDeclined(String category) {
    return 'Noted. $category is not held.';
  }

  @override
  String get depositNotAtFair => 'Only RM300 paid at a fair can hold a price.';

  @override
  String get categoryCurtain => 'curtains';

  @override
  String get categoryFlooring => 'flooring';

  @override
  String get categoryWallpaper => 'wallpaper';
}
