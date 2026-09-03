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
  String get stepUpgrade => 'Tambah apa-apa?';

  @override
  String get upgradeNone => 'Tidak, itu sahaja';

  @override
  String get upgradeIncluded =>
      'Trek biasa sudah termasuk. Ini adalah naik taraf.';

  @override
  String upgradeAdded(String name) {
    return '$name ditambah';
  }

  @override
  String upgradeOf(String parent) {
    return 'dengan $parent';
  }

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
  String get customerTitle => 'Pelanggan';

  @override
  String get customerName => 'Nama pelanggan';

  @override
  String get customerPhone => 'Telefon';

  @override
  String get customerOptional => 'Pilihan — boleh diisi kemudian';

  @override
  String get deliveryTitle => 'Kawasan penghantaran';

  @override
  String get deliveryNone => 'Bandar Melaka (tiada caj)';

  @override
  String deliveryCharge(String area) {
    return 'Perjalanan $area';
  }

  @override
  String get deliveryAskEarly => 'Ditanya sebelum jumlah, bukan selepas';

  @override
  String get save => 'Simpan';

  @override
  String get ratesTitle => 'Senarai harga';

  @override
  String get ratesEditOne => 'Tukar satu harga';

  @override
  String get ratesSearch => 'Cari produk';

  @override
  String get ratesNewRate => 'Kadar baharu (RM)';

  @override
  String get ratesNewMvp => 'Kadar MVP (RM)';

  @override
  String ratesCurrent(String rate) {
    return 'Sekarang $rate';
  }

  @override
  String get ratesInvalid => 'Itu bukan harga';

  @override
  String get ratesMvpTooHigh => 'Kadar MVP tidak boleh melebihi kadar biasa';

  @override
  String get ratesNoMatch => 'Produk tidak dijumpai';

  @override
  String ratesVersion(int version, int count) {
    return 'Versi $version · $count produk';
  }

  @override
  String get ratesExport => 'Eksport untuk Excel';

  @override
  String get ratesImport => 'Import fail yang disunting';

  @override
  String get ratesNoChanges => 'Tiada perubahan harga';

  @override
  String ratesReview(int count) {
    return '$count harga akan berubah. Tiada apa-apa digunakan sehingga anda sahkan.';
  }

  @override
  String get ratesApply => 'Gunakan harga ini';

  @override
  String ratesApplied(int version) {
    return 'Harga dikemas kini ke versi $version';
  }

  @override
  String get ratesErrors => 'Fail ini bermasalah. Tiada harga diubah.';

  @override
  String get ratesRestore => 'Pulihkan senarai harga asal';

  @override
  String ratesCustom(int version) {
    return 'Senarai harga telah disunting (versi $version)';
  }

  @override
  String get share => 'Kongsi sebut harga';

  @override
  String get pdfTitle => 'Sebut Harga';

  @override
  String get pdfCompany => 'Milan Langsir & Lantai';

  @override
  String get pdfQuoteNo => 'No. sebut harga';

  @override
  String get pdfDate => 'Tarikh';

  @override
  String get pdfRoom => 'Bilik';

  @override
  String get pdfProduct => 'Produk';

  @override
  String get pdfSize => 'Ukuran';

  @override
  String get pdfBilled => 'Dikira';

  @override
  String get pdfRate => 'Kadar';

  @override
  String get pdfAmount => 'Jumlah';

  @override
  String get pdfNotAnInvoice =>
      'Dokumen ini adalah sebut harga, bukan invois cukai.';

  @override
  String pdfValidity(int days) {
    return 'Sah selama $days hari';
  }

  @override
  String pdfPage(int page, int total) {
    return 'Halaman $page daripada $total';
  }

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
  String listFair(String code) {
    return 'Harga pesta $code';
  }

  @override
  String get listStandard => 'Harga biasa (bukan pesta)';

  @override
  String get listStandardProvisional =>
      'Harga biasa adalah sementara: langsir +20%, bidai +50%. Yang lain sama harga sepanjang tahun.';

  @override
  String expiredCardBanner(String code, String date) {
    return 'Ini kadar pesta $code dan telah tamat pada $date. Tidak sah untuk sebut harga harian.';
  }

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

  @override
  String get roleAdmin => 'Pentadbir';

  @override
  String get roleStaff => 'Kakitangan';

  @override
  String get roleParttime => 'Pekerja sambilan';

  @override
  String get syncTitle => 'Penyegerakan';

  @override
  String get signInTitle => 'Log masuk';

  @override
  String get signInPhone => 'Nombor telefon';

  @override
  String get signInPin => 'PIN';

  @override
  String get signInAction => 'Log masuk';

  @override
  String get signInFailed => 'Nombor atau PIN salah';

  @override
  String get signInOffline => 'Tiada sambungan. Cuba lagi bila ada isyarat.';

  @override
  String signInBusy(int seconds) {
    return 'Terlalu banyak cubaan. Tunggu $seconds saat.';
  }

  @override
  String get signInWhy =>
      'Log masuk sekali sebelum pesta jualan. Selepas itu app tetap boleh guna tanpa internet.';

  @override
  String signedInAs(String name, String role) {
    return 'Log masuk sebagai $name ($role)';
  }

  @override
  String get signOut => 'Log keluar';

  @override
  String get notSignedIn =>
      'Belum log masuk. Sebut harga tetap boleh dibuat; ia tidak dihantar ke pejabat.';

  @override
  String get serverAddress => 'Alamat pelayan';

  @override
  String get serverAddressInvalid =>
      'Masukkan alamat https, contoh milan.example.com';

  @override
  String get serverAddressChanged => 'Pelayan ditukar. Sila log masuk semula.';

  @override
  String get syncNow => 'Segerak sekarang';

  @override
  String get syncRunning => 'Sedang segerak';

  @override
  String get syncNever => 'Belum pernah disegerakkan';

  @override
  String syncLastAt(String time) {
    return 'Segerak terakhir $time';
  }

  @override
  String get syncOffline =>
      'Tiada sambungan. Semua masih berfungsi; ia akan menyusul kemudian.';

  @override
  String get syncSignedOut =>
      'Telefon ini telah dilog keluar. Log masuk semula untuk hantar sebut harga.';

  @override
  String syncPricesUpdated(int version) {
    return 'Harga dikemas kini ke versi $version';
  }

  @override
  String get syncPricesCurrent => 'Harga sudah terkini';

  @override
  String syncQueued(int count) {
    return '$count sebut harga menunggu untuk dihantar';
  }

  @override
  String syncSent(int count) {
    return '$count sebut harga telah dihantar';
  }

  @override
  String syncParked(int count) {
    return '$count sebut harga perlu perhatian';
  }

  @override
  String syncDisagreed(int count) {
    return '$count sebut harga dikira berbeza oleh pejabat. Ia tetap diterima dan ditanda untuk semakan.';
  }

  @override
  String get syncLocalEditDropped =>
      'Harga yang diubah pada telefon ini telah diganti dengan senarai pejabat.';

  @override
  String pricesFromServer(String time) {
    return 'Harga dari pejabat, setakat $time';
  }

  @override
  String get pricesBundled =>
      'Harga yang dihantar bersama app. Log masuk untuk dapatkan senarai pejabat.';

  @override
  String get pricesLocal =>
      'Harga yang diubah pada telefon ini. Ia akan diganti pada segerak berikutnya.';

  @override
  String get ratesServerOwned =>
      'Harga datang dari pejabat supaya setiap telefon beri harga yang sama. Perubahan di sini diterbitkan kepada semua.';

  @override
  String get ratesPublish => 'Terbitkan kepada semua';

  @override
  String ratesPublished(int version) {
    return 'Versi $version diterbitkan. Setiap telefon akan menerimanya pada segerak berikutnya.';
  }

  @override
  String get ratesPublishOffline =>
      'Penerbitan memerlukan sambungan, supaya setiap telefon dapat senarai yang sama.';

  @override
  String get ratesReadOnly => 'Hanya pejabat boleh menukar harga.';

  @override
  String get ratesCheckUpdates => 'Semak kemas kini';

  @override
  String get fairModeTitle => 'Mod pesta jualan';

  @override
  String get fairModePrepare => 'Sedia untuk pesta jualan';

  @override
  String get fairModeWhy =>
      'Muat turun kedua-dua senarai harga dan kosongkan baris gilir, supaya telefon boleh guna berhari-hari tanpa isyarat.';

  @override
  String get fairModeReady =>
      'Sedia. Kedua-dua senarai harga terkini dan tiada apa-apa menunggu untuk dihantar.';

  @override
  String get fairModeNotReady =>
      'Belum sedia. Sambung ke internet dan cuba lagi sebelum bertolak.';
}
