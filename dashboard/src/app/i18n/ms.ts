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
};
