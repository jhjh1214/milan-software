/**
 * Bahasa Melayu.
 *
 * The order lifecycle words are taken verbatim from
 * `mobile/lib/l10n/app_ms.arb`, for the same reason ZH takes its: the office
 * and the measurer are talking about one job, and two different words for
 * `material_selected` makes that a conversation about the software.
 */

import type { Strings } from './strings';

export const MS: Strings = {
  common: {
    loading: 'Sedang dimuatkan…',
    tryAgain: 'Cuba lagi',
    reload: 'Muat semula',
    cancel: 'Batal',
    save: 'Simpan',
    saving: 'Sedang menyimpan…',
    notAdmin: 'Hanya admin boleh buat ini.',
    signedOut: 'Sudah log keluar. Sila log masuk semula.',
    noAnswer: 'Tiada jawapan dari pelayan.',
    wentWrong: 'Ada sesuatu yang tidak kena.',
    serverAnswered: (status) => `Pelayan menjawab ${status}.`,
  },

  status: {
    confirmed: 'Disahkan',
    measurement_booked: 'Ukuran ditempah',
    measured: 'Sudah diukur',
    material_selected: 'Bahan dipilih',
    in_production: 'Sedang dibuat',
    ready: 'Sedia dipasang',
    installed: 'Sudah dipasang',
    closed: 'Selesai',
    cancelled: 'Dibatalkan',
  },

  channel: {
    fair: 'Pesta jualan',
    showroom: 'Bilik pameran',
    home_visit: 'Lawatan rumah',
    referral: 'Rujukan',
    phone: 'Telefon',
  },

  nav: {
    orders: 'Pesanan',
    measurement: 'Ukuran',
    priceChanges: 'Harga yang diubah',
    priceList: 'Senarai harga',
    reports: 'Laporan',
    people: 'Pengguna',
    signOut: 'Log keluar',
    language: 'Bahasa',
  },

  signIn: {
    phone: 'Nombor telefon',
    pin: 'PIN',
    action: 'Log masuk',
    busy: 'Sedang log masuk…',
    wrong: 'Nombor atau PIN salah.',
    throttled: 'Terlalu banyak cubaan. Tunggu sekejap dan cuba lagi.',
    offline: 'Tiada jawapan dari pelayan.',
    server: 'Ada masalah semasa log masuk.',
  },

  board: {
    title: 'Pesanan',
    showing: (shown, total) => `Menunjukkan ${shown} daripada ${total}`,
    stage: 'Peringkat',
    whereFrom: 'Dari mana',
    all: 'Semua',
    nothingMatches: 'Tiada pesanan yang sepadan dengan tapisan ini.',
    pendingSync: 'Menunggu penyegerakan',
    noName: 'Tiada nama',
    taken: 'diterima',
    rateHeldTo: (date) => `Harga dikunci hingga ${date}`,
    stillToMeasure: (lines) => `${lines} lagi belum diukur`,
    signedOut: 'Sudah log keluar. Log masuk semula untuk melihat pesanan.',
    wentWrong: 'Ada masalah semasa memuatkan pesanan.',
  },

  queue: {
    title: 'Senarai ukuran',
    show: 'Tunjuk',
    all: 'Semua',
    unbooked: 'Belum dihubungi',
    booked: 'Lawatan ditempah',
    jobsAcrossTrips: (jobs, trips) =>
      `${jobs} pesanan dalam ${trips} perjalanan`,
    stillToMeasure: (lines) => `${lines} lagi belum diukur`,
    nothingWaiting: 'Tiada pesanan menunggu lawatan.',
    noTripsMatch: 'Tiada perjalanan yang sepadan dengan tapisan ini.',
    noName: 'Tiada nama direkodkan',
    waiting: (days) => `Menunggu ${days} hari`,
    someBooked: (booked, jobs) => `${booked} daripada ${jobs} ditempah`,
    oneVisitCovers: (orders) =>
      `${orders} pesanan untuk satu pelanggan — satu lawatan mencukupi`,
    noPhone:
      'Tiada nombor telefon, jadi ini tidak dapat dikumpulkan dengan yang lain.',
    pendingSync: 'menunggu penyegerakan',
    toMeasure: (unmeasured, lines) =>
      `${unmeasured} daripada ${lines} perlu diukur`,
    materialsToChoose: (materials) => `${materials} bahan perlu dipilih`,
    bookedOn: (date) => `Ditempah ${date}`,
    notBooked: 'Belum ditempah',
    tripTotal: (total, oldest) =>
      `Jumlah perjalanan ${total} · deposit terawal ${oldest}`,
    signedOut: 'Sudah log keluar. Log masuk semula untuk melihat senarai.',
    wentWrong: 'Ada masalah semasa memuatkan senarai.',
  },

  overrides: {
    title: 'Harga yang diubah dengan tangan',
    week: 'Minggu',
    earlier: '← Lebih awal',
    later: 'Kemudian →',
    quietWeek: 'Tiada sesiapa mengubah harga minggu ini.',
    netForWeek: (changes, net) => `${changes} perubahan, bersih ${net}`,
    caption: (from, to) =>
      `Setiap harga yang diubah dengan tangan antara ${from} dan ${to}`,
    who: 'Siapa',
    from: 'Dari',
    to: 'Kepada',
    change: 'Perubahan',
    why: 'Sebab',
    when: 'Bila',
    notAdmin: 'Hanya admin boleh melihat log perubahan harga.',
    wentWrong: 'Ada masalah semasa memuatkan log.',
  },

  role: {
    admin: 'Admin',
    staff: 'Kakitangan',
    parttime: 'Separuh masa',
  },

  people: {
    title: 'Pengguna',
    addSomebody: 'Tambah orang',
    name: 'Nama',
    phone: 'Nombor telefon',
    pin: 'PIN',
    role: 'Peranan',
    add: 'Tambah',
    status: 'Status',
    actions: 'Tindakan',
    active: 'Aktif',
    left: (date) => `Berhenti ${date}`,
    you: 'Anda',
    removeAccess: 'Tarik balik akses',
    letBackIn: 'Benarkan semula',
    keepIt: 'Jangan',
    removeTitle: (name) => `Tarik balik akses ${name}?`,
    removeWhat:
      'Telefon mereka akan log keluar kali seterusnya ia menghubungi pelayan. ' +
      'Sebut harga dan bayaran mereka kekal, dan masih atas nama mereka.',
    typeToConfirm: 'Taip nama ini untuk mengesahkan:',
    canSignInNow: (name) => `${name} boleh log masuk sekarang.`,
    cannotSignIn: (name) => `${name} tidak boleh log masuk lagi.`,
    cannotSignInAndOut: (name, handsets) =>
      `${name} tidak boleh log masuk lagi. ${handsets} telefon telah log keluar.`,
    canSignInAgain: (name) =>
      `${name} boleh log masuk semula. Mereka perlu log masuk sekali lagi.`,
    phoneTaken: 'Nombor itu sudah digunakan oleh orang lain.',
    weakPin:
      'Ditolak — pastikan PIN empat digit ke atas dan bukan nombor yang mudah.',
    notAdmin: 'Hanya admin boleh menguruskan pengguna.',
    noSuchPerson: 'Orang itu tidak wujud lagi.',
    wentWrong: 'Ada sesuatu yang tidak kena.',
  },

  publish: {
    title: 'Terbitkan senarai harga',
    whichList: 'Senarai mana',
    fair: 'pesta jualan',
    standard: 'biasa',
    cardAsJson: 'Senarai harga, dalam JSON',
    or: 'atau',
    showMeWhatChanges: 'Tunjuk apa yang berubah',
    working: 'Sedang diproses…',
    publishThis: 'Terbitkan ini',
    publishing: 'Sedang menerbitkan…',
    publishAnother: 'Terbitkan satu lagi',
    publishedAs: (version) =>
      `Diterbitkan sebagai versi ${version}. Setiap telefon akan mendapatnya ` +
      `pada penyegerakan seterusnya.`,
    nothingWouldChange: (unchanged) =>
      `Tiada apa-apa yang berubah. ${unchanged} peraturan, semuanya pada harga sama.`,
    summary: (changed, added, removed, unchanged) =>
      `${changed} harga berubah, ${added} ditambah, ${removed} dibuang, ` +
      `${unchanged} tidak berubah.`,
    net: (amount) => `Bersih ${amount}.`,
    pricesThatMove: 'Harga yang berubah',
    product: 'Produk',
    from: 'Dari',
    to: 'Kepada',
    change: 'Perubahan',
    productsThatDisappear: 'Produk yang hilang',
    wasPriced: (rate) => `dahulu ${rate}`,
    newProducts: 'Produk baharu',
    liveNote:
      'Ini akan menjadi senarai harga yang digunakan. Yang digantikan tetap ' +
      'disimpan, jadi sebut harga yang dibuat atasnya masih boleh dijelaskan.',
    notAdmin: 'Hanya admin boleh menerbitkan senarai harga.',
    notACard: 'Pelayan tidak menerima senarai harga itu.',
    versionMustGoUp:
      'Pelayan menolaknya — pastikan nombor versi lebih tinggi daripada sekarang.',
    wentWrong: 'Ada sesuatu yang tidak kena.',
  },

  order: {
    backToOrders: '← Pesanan',
    numberPending: 'Nombor pesanan menunggu penyegerakan',
    noName: 'Tiada nama',
    estimate: 'Anggaran',
    taken: 'Diterima',
    referencePrice:
      'Ini anggaran. Selepas diukur, harganya sama atau lebih rendah, tidak ' +
      'akan lebih tinggi.',
    rateHeldTo: (date) => `Harga dikunci hingga ${date}`,
    whatWasOrdered: 'Apa yang dipesan',
    sizeEstimate: (size) => `${size} (anggaran)`,
    sizeMeasured: (estimate, measured) => `${estimate} → ${measured} diukur`,
    basis: (quantity, unit, rate, band, version, discount) =>
      `${quantity} ${unit} pada ${rate}${band}` +
      ` · senarai v${version}${discount}`,
    materialToChoose: 'Bahan belum dipilih — disebut harga pada yang termahal',
    priceChangedByHand: 'Harga diubah dengan tangan',
    pricesChangedByHand: 'Harga yang diubah dengan tangan',
    movedBy: (before, after, who) => `${before} kepada ${after}, oleh ${who}`,
    whatHasHappened: 'Apa yang sudah berlaku',
    noSuchOrder: 'Pesanan itu tidak wujud.',
    signedOut: 'Sudah log keluar. Log masuk semula untuk melihat pesanan ini.',
    wentWrong: 'Ada masalah semasa memuatkan pesanan ini.',
  },

  buyer: {
    title: 'Butiran pelanggan untuk invois',
    whyOverThreshold:
      'Pesanan ini melebihi RM10,000, jadi mengikut undang-undang invois ' +
      'memerlukan butiran pelanggan sendiri.',
    whyRequested:
      'Pelanggan meminta e-invois, jadi butiran ini diperlukan tanpa mengira ' +
      'jumlahnya.',
    nobodyHasTaken: 'Belum ada sesiapa mengambil butiran ini.',
    name: 'Nama',
    tin: 'TIN',
    id: 'Pengenalan',
    address: 'Alamat',
    msic: 'MSIC',
    taken: 'Diambil',
    complete: 'Semua yang diperlukan invois sudah ada.',
    stillNeeded: 'Masih diperlukan:',
    missingName: 'nama penuh, seperti dalam IC atau pendaftaran syarikat',
    missingIdentifier: 'TIN, atau nombor pengenalan berserta jenisnya',
    missingAddress: 'alamat penuh — jalan, bandar, negeri dan poskod',
    notAnIssuer:
      'Butiran ini dikumpulkan supaya invois boleh dikeluarkan dalam sistem ' +
      'perakaunan. Papan pemuka ini tidak mengeluarkan invois.',
    addThese: 'Tambah butiran',
    correctThese: 'Betulkan butiran',
    onlyWhatYouChange:
      'Hanya apa yang anda ubah akan dihantar. Kotak yang anda kosongkan akan ' +
      'memadam medan itu; yang tidak disentuh mengekalkan apa yang telefon ' +
      'ambil sejak itu.',
    notStated: 'tidak dinyatakan',
    askedForEinvoice: 'Pelanggan meminta e-invois',
    fieldName: 'Nama, seperti dalam IC atau pendaftaran syarikat',
    fieldTin: 'TIN',
    fieldIdType: 'Jenis pengenalan',
    fieldIdNumber: 'Nombor pengenalan',
    fieldAddress1: 'Alamat baris 1',
    fieldAddress2: 'Alamat baris 2 (pilihan)',
    fieldCity: 'Bandar',
    fieldState: 'Negeri',
    fieldPostcode: 'Poskod',
    fieldMsic: 'Kod MSIC (pembeli syarikat sahaja)',
    savedComplete: 'Disimpan. Semua yang diperlukan invois sudah ada.',
    savedIncomplete: 'Disimpan. Sebahagiannya masih belum lengkap.',
    refusedStale:
      'Tidak disimpan — seseorang mengambil butiran ini di telefon baru-baru ' +
      'ini. Muat semula untuk melihat apa yang mereka ambil, kemudian betulkan ' +
      'sekali lagi.',
    refusedUnknown: 'Tidak disimpan — pelayan belum ada rekod pesanan ini.',
    refusedOther: (reason) => `Tidak disimpan — pelayan menolaknya (${reason}).`,
  },

  reports: {
    title: 'Laporan',
    variance: 'Anggaran lawan harga akhir',
    fairs: 'Prestasi pesta jualan',
    balances: 'Baki belum dijelaskan',
    deposits: 'Deposit yang tidak diambil',
    notAdmin: 'Hanya admin boleh membaca laporan.',
    wentWrong: 'Ada sesuatu yang tidak kena.',

    varianceBias:
      'Sebut harga membundarkan setiap kuantiti ke atas dan bil akhir ' +
      'menggunakan ukuran sebenar, jadi setiap anggaran yang jujur akan ' +
      'kelihatan tinggi. Yang ditunjukkan di sini ialah siapa yang jauh lebih ' +
      'tersasar daripada orang lain — bukan siapa yang tersasar.',
    nothingPricedYet:
      'Belum ada harga akhir, jadi tiada apa untuk dibandingkan. Harga akhir ' +
      'ditetapkan semasa ukuran di tapak.',
    varianceCaption: 'Anggaran berbanding harga akhir, mengikut jurujual',
    salesperson: 'Jurujual',
    priced: 'Sudah berharga',
    awaiting: 'Menunggu',
    estimated: 'Dianggarkan',
    final: 'Akhir',
    varianceColumn: 'Perbezaan',
    overEstimate: 'Melebihi anggaran',
    nobodyRecorded: 'Tiada direkodkan',

    noFairsYet: 'Belum ada pesanan daripada pesta jualan.',
    fairsCaption: 'Apa yang dicapai oleh setiap pesta jualan',
    fair: 'Pesta jualan',
    dates: 'Tarikh',
    orders: 'Pesanan',
    quoted: 'Disebut harga',
    depositsTaken: 'Deposit diterima',
    ratesHeld: 'Harga dikunci',
    noPromotion: 'Tiada promosi pada senarai harga',

    agedFromDeposit:
      'Dikira dari tarikh deposit, satu-satunya tarikh yang sistem ini tahu. ' +
      'Tiada apa-apa di sini yang tertunggak.',
    allEstimated:
      'Setiap jumlah di bawah masih sebut harga — jumlah paling banyak yang ' +
      'mungkin terhutang, bukan bil.',
    someEstimated:
      'Sebahagian jumlah masih sebut harga, ditanda di bawah; sebut harga ' +
      'ialah jumlah paling banyak yang mungkin terhutang, bukan bil.',
    bucketRange: (from, to) => `${from}-${to} hari`,
    bucketOver: (from) => `Melebihi ${from} hari`,
    bucketOrders: (orders) => `${orders} pesanan`,
    outstandingOfWhich: (total, estimated) =>
      `Belum dijelaskan ${total}, ${estimated} daripadanya masih anggaran`,
    nothingOutstanding: 'Tiada baki belum dijelaskan.',
    balancesCaption: 'Baki belum dijelaskan',
    order: 'Pesanan',
    customer: 'Pelanggan',
    stage: 'Peringkat',
    sinceDeposit: 'Sejak deposit',
    total: 'Jumlah',
    paid: 'Dibayar',
    balance: 'Baki',
    days: (days) => `${days} hari`,
    estimateMark: 'angg.',
    pendingSync: 'menunggu penyegerakan',
    noName: 'Tiada nama',

    last: 'Sepanjang',
    weeks: (weeks) => `${weeks} minggu`,
    declinesNote:
      'Apa yang disebut harga dalam sesuatu kategori tetapi tidak dideposit. ' +
      'Yang tidak dijawab diasingkan daripada yang ditolak: “mereka kata ' +
      'tidak” dan “tiada sesiapa bertanya dengan betul” adalah dua masalah ' +
      'yang berbeza.',
    declinesCaption: 'Deposit kategori yang tidak diambil',
    category: 'Kategori',
    categoryCurtain: 'Langsir',
    categoryFlooring: 'Lantai',
    categoryWallpaper: 'Kertas dinding',
    asked: 'Ditanya',
    collected: 'Diterima',
    declined: 'Ditolak',
    linesRemoved: 'Baris dibuang',
    dismissed: 'Tidak dijawab',
    takeRate: 'Kadar berjaya',
    leftOnTheTable: 'Nilai terlepas',
    takeRateOf: (taken, asked) => `${taken} daripada ${asked}`,
  },
};
