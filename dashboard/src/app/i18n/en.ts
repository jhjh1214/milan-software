/**
 * English. The reference wording — the other two are translations of this.
 *
 * Kept as the file to edit first when copy changes, so ZH and MS are always
 * translating something that exists rather than each other.
 */

import type { Strings } from './strings';

export const EN: Strings = {
  common: {
    loading: 'Loading…',
    tryAgain: 'Try again',
    reload: 'Reload',
    cancel: 'Cancel',
    save: 'Save',
    saving: 'Saving…',
    notAdmin: 'Only an admin can do that.',
    signedOut: 'Signed out. Sign in again.',
    noAnswer: 'No answer from the server.',
    wentWrong: 'Something went wrong.',
    serverAnswered: (status) => `The server answered ${status}.`,
  },

  status: {
    confirmed: 'Confirmed',
    measurement_booked: 'Measurement booked',
    measured: 'Measured',
    material_selected: 'Material chosen',
    in_production: 'In production',
    ready: 'Ready to install',
    installed: 'Installed',
    closed: 'Closed',
    cancelled: 'Cancelled',
  },

  channel: {
    fair: 'Fair',
    showroom: 'Showroom',
    home_visit: 'Home visit',
    referral: 'Referral',
    phone: 'Phone',
  },

  nav: {
    orders: 'Orders',
    measurement: 'Measurement',
    priceChanges: 'Price changes',
    priceList: 'Price list',
    reports: 'Reports',
    people: 'People',
    signOut: 'Sign out',
    language: 'Language',
  },

  signIn: {
    phone: 'Phone',
    pin: 'PIN',
    action: 'Sign in',
    busy: 'Signing in…',
    wrong: 'That phone and PIN do not match.',
    throttled: 'Too many tries. Wait a moment and try again.',
    offline: 'No answer from the server.',
    server: 'Something went wrong signing in.',
  },

  board: {
    title: 'Orders',
    showing: (shown, total) => `Showing ${shown} of ${total}`,
    stage: 'Stage',
    whereFrom: 'Where from',
    all: 'All',
    nothingMatches: 'Nothing matches these filters.',
    pendingSync: 'Pending sync',
    noName: 'No name',
    taken: 'taken',
    rateHeldTo: (date) => `Rate held to ${date}`,
    stillToMeasure: (lines) => `${lines} still to measure`,
    signedOut: 'Signed out. Sign in again to see the board.',
    wentWrong: 'Something went wrong loading the board.',
  },

  queue: {
    title: 'Measurement queue',
    show: 'Show',
    all: 'All',
    unbooked: 'Nobody called yet',
    booked: 'Visit booked',
    jobsAcrossTrips: (jobs, trips) =>
      `${jobs} job${jobs === 1 ? '' : 's'} across ` +
      `${trips} trip${trips === 1 ? '' : 's'}`,
    stillToMeasure: (lines) => `${lines} still to measure`,
    nothingWaiting: 'Nothing is waiting for a visit.',
    noTripsMatch: 'No trips match this filter.',
    noName: 'No name recorded',
    waiting: (days) => `Waiting ${days} day${days === 1 ? '' : 's'}`,
    someBooked: (booked, jobs) => `${booked} of ${jobs} booked`,
    oneVisitCovers: (orders) =>
      `${orders} orders for one customer — one visit covers them all`,
    noPhone: 'No phone recorded, so this could not be grouped with anything else.',
    pendingSync: 'pending sync',
    toMeasure: (unmeasured, lines) => `${unmeasured} of ${lines} to measure`,
    materialsToChoose: (materials) =>
      `${materials} material${materials === 1 ? '' : 's'} to choose`,
    bookedOn: (date) => `Booked ${date}`,
    notBooked: 'Not booked',
    tripTotal: (total, oldest) => `Trip total ${total} · oldest deposit ${oldest}`,
    signedOut: 'Signed out. Sign in again to see the queue.',
    wentWrong: 'Something went wrong loading the queue.',
  },

  overrides: {
    title: 'Prices changed by hand',
    week: 'Week',
    earlier: '← Earlier',
    later: 'Later →',
    quietWeek: 'Nobody changed a price this week.',
    netForWeek: (changes, net) => `${changes} changes, ${net} net`,
    caption: (from, to) =>
      `Every price moved by hand between ${from} and ${to}`,
    who: 'Who',
    from: 'From',
    to: 'To',
    change: 'Change',
    why: 'Why',
    when: 'When',
    notAdmin: 'Only an admin can see the override log.',
    wentWrong: 'Something went wrong loading the log.',
  },

  role: {
    admin: 'Admin',
    staff: 'Staff',
    parttime: 'Part-timer',
  },

  people: {
    title: 'People',
    addSomebody: 'Add somebody',
    name: 'Name',
    phone: 'Phone',
    pin: 'PIN',
    role: 'Role',
    add: 'Add',
    status: 'Status',
    actions: 'Actions',
    active: 'Active',
    left: (date) => `Left ${date}`,
    you: 'You',
    removeAccess: 'Remove access',
    letBackIn: 'Let back in',
    keepIt: 'Keep it',
    removeTitle: (name) => `Remove ${name}'s access?`,
    removeWhat:
      'Their handset signs out the next time it reaches the server. Their ' +
      'quotes and payments stay, and still name them.',
    typeToConfirm: 'Type this name to confirm:',
    canSignInNow: (name) => `${name} can sign in now.`,
    cannotSignIn: (name) => `${name} can no longer sign in.`,
    cannotSignInAndOut: (name, handsets) =>
      `${name} can no longer sign in. ${handsets} handset(s) signed out.`,
    canSignInAgain: (name) => `${name} can sign in again. They will have to.`,
    phoneTaken: 'Somebody already signs in with that number.',
    weakPin: 'Refused — check the PIN is four or more digits and not obvious.',
    notAdmin: 'Only an admin can manage people.',
    noSuchPerson: 'That person no longer exists.',
    wentWrong: 'Something went wrong.',
  },
};
