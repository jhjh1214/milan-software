// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Malay (`ms`).
class LMs extends L {
  LMs([String locale = 'ms']) : super(locale);

  @override
  String get appTitle => 'Milan Sebut Harga';

  @override
  String get languageChinese => '中文';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageMalay => 'Bahasa Melayu';

  @override
  String get language => 'Bahasa';

  @override
  String get quoteTitle => 'Sebut Harga';

  @override
  String get newQuote => 'Sebut harga baharu';

  @override
  String get addWindow => 'Tambah tingkap';

  @override
  String get emptyQuoteTitle => 'Belum ada tingkap';

  @override
  String get emptyQuoteAction => 'Tekan di bawah untuk tambah tingkap pertama';

  @override
  String get stepRoom => 'Bilik yang mana?';

  @override
  String get stepProduct => 'Produk apa?';

  @override
  String get stepMaterial => 'Bahan apa?';

  @override
  String get stepSizes => 'Ukuran';

  @override
  String get stepFamily => 'Kategori yang mana?';

  @override
  String get familyCurtain => 'Langsir';

  @override
  String get familyBlind => 'Bidai';

  @override
  String get familyTrack => 'Trek & Rod';

  @override
  String get familyFlooring => 'Lantai';

  @override
  String get familyWallpaper => 'Kertas Dinding';

  @override
  String get familyAddon => 'Tambahan';

  @override
  String get familyService => 'Perkhidmatan';

  @override
  String get materialLater => 'Bahan dipilih semasa pengukuran';

  @override
  String get materialLaterNote =>
      'Disebut harga pada bahan termahal. Pilihan lebih murah menurunkannya.';

  @override
  String stepProgress(int current, int total, String room) {
    return 'Tingkap $current daripada $total · $room';
  }

  @override
  String get roomLiving => 'Ruang tamu';

  @override
  String get roomMaster => 'Bilik utama';

  @override
  String get roomBedroom => 'Bilik tidur';

  @override
  String get roomKitchen => 'Dapur';

  @override
  String get roomBalcony => 'Balkoni';

  @override
  String get roomStudy => 'Bilik belajar';

  @override
  String get roomOther => 'Lain-lain';

  @override
  String get roomCustom => 'Taip nama';

  @override
  String get width => 'Lebar';

  @override
  String get height => 'Tinggi';

  @override
  String get quantity => 'Kuantiti';

  @override
  String sameWindows(int count) {
    return '$count tingkap serupa';
  }

  @override
  String get unitFoot => 'kaki';

  @override
  String get unitInch => 'inci';

  @override
  String get unitMm => 'mm';

  @override
  String get unitCm => 'cm';

  @override
  String get unitMetre => 'm';

  @override
  String get unitSqft => 'kaki persegi';

  @override
  String billedAs(String qty, String unit) {
    return 'dikira $qty $unit';
  }

  @override
  String enteredAs(String value) {
    return 'dimasukkan $value';
  }

  @override
  String minQtyApplied(String qty, String unit) {
    return 'minimum $qty $unit';
  }

  @override
  String get errorInvalidDimension => 'Ukuran ini tidak dapat dibaca';

  @override
  String get errorDimensionRequired => 'Masukkan ukuran';

  @override
  String get errorNoRate => 'Produk ini tiada kadar lengkap. Beritahu pejabat.';

  @override
  String warnUnitLooksWrong(
    String value,
    String unit,
    String converted,
    String suggestion,
  ) {
    return '$value $unit = $converted. Adakah anda maksudkan $suggestion?';
  }

  @override
  String warnSwitchTo(String unit) {
    return 'Tukar ke $unit';
  }

  @override
  String warnDropVeryShort(String value) {
    return 'Tinggi hanya $value. Betul ke?';
  }

  @override
  String warnNearBandEdge(String edge) {
    return 'Baru melebihi $edge. Sila semak ukuran.';
  }

  @override
  String warnBandBothPrices(String lower, String lowerPrice, String upper) {
    return 'Sehingga $lower: $lowerPrice · Melebihi $upper';
  }

  @override
  String get runningTotal => 'Jumlah';

  @override
  String get subtotal => 'Jumlah kecil';

  @override
  String get lineTotal => 'Jumlah baris';

  @override
  String depositFloorRow(String amount) {
    return 'Sebut harga minimum (deposit $amount)';
  }

  @override
  String get depositFloorExplain =>
      'Sebut harga tidak akan kurang daripada deposit, supaya deposit tidak melebihi tempahan.';

  @override
  String get disclaimerTitle => 'Harga rujukan';

  @override
  String get disclaimerBody =>
      'Sebut harga ini dibundarkan ke atas dan untuk rujukan sahaja. Selepas pengukuran di tapak, harga akhir adalah sama atau lebih rendah, tidak akan lebih tinggi.';

  @override
  String get provisionalCardBanner =>
      'Senarai harga belum disahkan. Jangan beri sebut harga kepada pelanggan.';

  @override
  String get delete => 'Padam';

  @override
  String get deleted => 'Dipadam';

  @override
  String get undo => 'Batal';

  @override
  String get back => 'Kembali';

  @override
  String get next => 'Seterusnya';

  @override
  String get done => 'Selesai';

  @override
  String get cancel => 'Batal';

  @override
  String get confirm => 'Sahkan';

  @override
  String get keypadClear => 'Kosongkan';

  @override
  String get keypadBackspace => 'Padam';

  @override
  String get keypadDone => 'OK';

  @override
  String get bandLower => 'Sehingga 10ka';

  @override
  String get bandUpper => 'Melebihi 10ka';

  @override
  String get tierMvp => 'Kadar MVP';

  @override
  String get tierStandard => 'Kadar biasa';
}
