#!/usr/bin/env node
/**
 * Square 15 — Full Demo Data Seeder & Flow Validator
 *
 * Seeds Firestore with realistic demo data, then validates every
 * critical app flow to ensure no dead ends exist.
 *
 * Usage:  node scripts/seed_demo_data.js
 */

const admin = require('firebase-admin');
const path = require('path');

// ── Firebase init ──────────────────────────────────────────────
const serviceAccount = require(
  path.resolve(__dirname, '../../square_15-master/assets/firebase-adminsdk.json')
);
if (!admin.apps.length) {
  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount),
  });
}
const db = admin.firestore();

// ── Constants ──────────────────────────────────────────────────
const DEMO_CUSTOMER_UID  = 'demo_customer_001';
const DEMO_ARTISAN_UID   = 'demo_artisan_001';
const DEMO_ADMIN_UID     = 'demo_admin_001';
const DEMO_PARTNER_ID    = 'demo_partner_001';
const NOW = new Date();
const TS  = admin.firestore.Timestamp.fromDate(NOW);

function isoDate(daysOffset = 0) {
  const d = new Date(NOW);
  d.setDate(d.getDate() + daysOffset);
  return d.toISOString().split('T')[0];
}

// ── Stats ──────────────────────────────────────────────────────
let created = 0;
let errors  = 0;
const flowResults = [];

async function safeSet(ref, data, label) {
  try {
    await ref.set(data, { merge: true });
    created++;
    return true;
  } catch (e) {
    console.error(`  ✗ ${label}: ${e.message}`);
    errors++;
    return false;
  }
}

// ═══════════════════════════════════════════════════════════════
// 1. SEED USERS
// ═══════════════════════════════════════════════════════════════
async function seedUsers() {
  console.log('\n📌 Seeding users...');

  await safeSet(db.collection('users').doc(DEMO_CUSTOMER_UID), {
    uid: DEMO_CUSTOMER_UID,
    email: 'demo.customer@square15test.co.za',
    name: 'Demo Customer',
    contact: 27821234567,
    balance: '500.00',
    isAdmin: false,
    isServiceProvider: false,
    isUser: true,
    isVerified: true,
    lat: '-26.2041',
    lng: '28.0473',
    deviceToken: 'demo_fcm_token_customer',
    fcm_token: 'demo_fcm_token_customer',
    fcm_token_updated_at: TS,
    image: '',
    is_online: true,
    last_seen: TS,
    referred_by_partner_id: '',
    referral_code_used: '',
    building_name: '',
  }, 'demo customer');

  await safeSet(db.collection('users').doc(DEMO_ARTISAN_UID), {
    uid: DEMO_ARTISAN_UID,
    email: 'demo.artisan@square15test.co.za',
    name: 'Demo Artisan (Plumber)',
    contact: 27839876543,
    balance: '1200.00',
    isAdmin: false,
    isServiceProvider: true,
    isUser: false,
    isVerified: true,
    lat: '-26.1950',
    lng: '28.0340',
    deviceToken: 'demo_fcm_token_artisan',
    fcm_token: 'demo_fcm_token_artisan',
    fcm_token_updated_at: TS,
    image: '',
    is_online: true,
    last_seen: TS,
  }, 'demo artisan (user doc)');

  await safeSet(db.collection('users').doc(DEMO_ADMIN_UID), {
    uid: DEMO_ADMIN_UID,
    email: 'demo.admin@square15test.co.za',
    name: 'Demo Admin',
    contact: 27800000001,
    balance: '0',
    isAdmin: true,
    isServiceProvider: false,
    isUser: false,
    isVerified: true,
    lat: '-26.2041',
    lng: '28.0473',
    is_online: true,
    last_seen: TS,
  }, 'demo admin');
}

// ═══════════════════════════════════════════════════════════════
// 2. SEED SERVICE PROVIDER
// ═══════════════════════════════════════════════════════════════
async function seedServiceProvider() {
  console.log('\n📌 Seeding service provider...');

  await safeSet(db.collection('serviceProvider').doc(DEMO_ARTISAN_UID), {
    uid: DEMO_ARTISAN_UID,
    name: 'Demo Artisan (Plumber)',
    email: 'demo.artisan@square15test.co.za',
    positionLat: -26.1950,
    positionLong: 28.0340,
    mainCategory: 'Plumbing',
    subCategory: 'General Plumbing',
    isVerified: true,
    imageUrl: '',
    accountLinked: true,
    status: 'publish',
    deviceToken: 'demo_fcm_token_artisan',
    fcm_token: 'demo_fcm_token_artisan',
    fcm_token_updated_at: TS,
    is_online: true,
    last_seen: TS,
  }, 'service provider profile');
}

// ═══════════════════════════════════════════════════════════════
// 3. SEED CATEGORIES & TASKS
// ═══════════════════════════════════════════════════════════════
async function seedCategories() {
  console.log('\n📌 Seeding categories & tasks...');

  const cats = [
    { id: 'cat_plumbing', name: 'Plumbing', parent_id: '', status: 'active', image: '' },
    { id: 'cat_electrical', name: 'Electrical', parent_id: '', status: 'active', image: '' },
    { id: 'cat_painting', name: 'Painting', parent_id: '', status: 'active', image: '' },
    { id: 'cat_cleaning', name: 'Cleaning', parent_id: '', status: 'active', image: '' },
    { id: 'cat_locksmith', name: 'Locksmith', parent_id: '', status: 'active', image: '' },
  ];
  for (const c of cats) {
    await safeSet(db.collection('categories').doc(c.id), c, `category ${c.name}`);
  }

  const tasks = [
    { id: 'task_fix_tap', name: 'Fix Leaking Tap', categoryId: 'cat_plumbing', cost: '350', status: 'active' },
    { id: 'task_unblock_drain', name: 'Unblock Drain', categoryId: 'cat_plumbing', cost: '500', status: 'active' },
    { id: 'task_geyser_repair', name: 'Geyser Repair', categoryId: 'cat_plumbing', cost: '2500', status: 'active' },
    { id: 'task_power_outlet', name: 'Install Power Outlet', categoryId: 'cat_electrical', cost: '650', status: 'active' },
    { id: 'task_painting_room', name: 'Paint Room (standard)', categoryId: 'cat_painting', cost: '1800', status: 'active' },
    { id: 'task_deep_clean', name: 'Deep Clean (3-bed house)', categoryId: 'cat_cleaning', cost: '1200', status: 'active' },
    { id: 'task_lock_change', name: 'Change Door Lock', categoryId: 'cat_locksmith', cost: '450', status: 'active' },
  ];
  for (const t of tasks) {
    await safeSet(db.collection('tasks').doc(t.id), t, `task ${t.name}`);
  }
}

// ═══════════════════════════════════════════════════════════════
// 4. SEED BOOKINGS (various states)
// ═══════════════════════════════════════════════════════════════
async function seedBookings() {
  console.log('\n📌 Seeding bookings (futureBookings)...');

  const bookings = [
    // ── Pending booking (customer waiting for artisan) ──
    {
      id: 'demo_booking_pending',
      user_id: DEMO_CUSTOMER_UID,
      service_provider_id: DEMO_ARTISAN_UID,
      task_id: 'task_fix_tap',
      task_name: 'Fix Leaking Tap',
      scheduled_date: isoDate(3),
      scheduled_time: '10:00',
      created_at: TS,
      status: 'pending',
      cost: '350',
      description: 'Kitchen tap has been dripping for 2 days',
      user_confirmed: 'yes',
      artisan_confirmed: 'pending',
      one_day_reminder_sent: 'no',
      one_hour_reminder_sent: 'no',
      reassigned_count: 0,
      service_on_location: true,
      provided_address: '15 Main Rd, Sandton, Johannesburg',
      user_lat: '-26.2041',
      user_lng: '28.0473',
      is_rfq: 'no',
      category_id: 'cat_plumbing',
      category_name: 'Plumbing',
      wallet_deducted: false,
      wallet_refunded: false,
    },

    // ── Confirmed booking (both parties confirmed, awaiting service) ──
    {
      id: 'demo_booking_confirmed',
      user_id: DEMO_CUSTOMER_UID,
      service_provider_id: DEMO_ARTISAN_UID,
      task_id: 'task_unblock_drain',
      task_name: 'Unblock Drain',
      scheduled_date: isoDate(1),
      scheduled_time: '14:30',
      created_at: TS,
      status: 'confirmed',
      cost: '500',
      description: 'Bathroom drain blocked completely',
      user_confirmed: 'yes',
      artisan_confirmed: 'yes',
      one_day_reminder_sent: 'yes',
      one_hour_reminder_sent: 'no',
      reassigned_count: 0,
      service_on_location: true,
      provided_address: '22 Oak Ave, Rosebank, Johannesburg',
      user_lat: '-26.1460',
      user_lng: '28.0436',
      is_rfq: 'no',
      category_id: 'cat_plumbing',
      category_name: 'Plumbing',
      wallet_deducted: true,
      wallet_deducted_amount: 500,
      wallet_refunded: false,
      job_ids: ['demo_tm_confirmed'],
    },

    // ── Completed booking (with rating) ──
    {
      id: 'demo_booking_completed',
      user_id: DEMO_CUSTOMER_UID,
      service_provider_id: DEMO_ARTISAN_UID,
      task_id: 'task_power_outlet',
      task_name: 'Install Power Outlet',
      scheduled_date: isoDate(-5),
      scheduled_time: '09:00',
      created_at: admin.firestore.Timestamp.fromDate(new Date(NOW.getTime() - 7 * 86400000)),
      status: 'completed',
      cost: '650',
      description: 'New power outlet in home office',
      user_confirmed: 'yes',
      artisan_confirmed: 'yes',
      one_day_reminder_sent: 'yes',
      one_hour_reminder_sent: 'yes',
      reassigned_count: 0,
      service_on_location: true,
      provided_address: '8 Tech Park, Midrand',
      user_lat: '-25.9800',
      user_lng: '28.1280',
      is_rfq: 'no',
      category_id: 'cat_electrical',
      category_name: 'Electrical',
      wallet_deducted: true,
      wallet_deducted_amount: 650,
      wallet_refunded: false,
      job_ids: ['demo_tm_completed'],
      work_images: [],
    },

    // ── Cancelled booking ──
    {
      id: 'demo_booking_cancelled',
      user_id: DEMO_CUSTOMER_UID,
      service_provider_id: DEMO_ARTISAN_UID,
      task_id: 'task_painting_room',
      task_name: 'Paint Room (standard)',
      scheduled_date: isoDate(-2),
      scheduled_time: '08:00',
      created_at: admin.firestore.Timestamp.fromDate(new Date(NOW.getTime() - 4 * 86400000)),
      status: 'cancelled',
      cost: '1800',
      description: 'Bedroom repaint — cancelled due to schedule conflict',
      user_confirmed: 'yes',
      artisan_confirmed: 'no',
      reassigned_count: 0,
      service_on_location: true,
      provided_address: '5 Cypress Rd, Bryanston',
      user_lat: '-26.0617',
      user_lng: '28.0193',
      is_rfq: 'no',
      category_id: 'cat_painting',
      category_name: 'Painting',
      wallet_deducted: true,
      wallet_deducted_amount: 1800,
      wallet_refunded: true,
      wallet_refund_amount: 1800,
      wallet_refund_reason: 'Artisan did not confirm in time',
      wallet_refund_txn_id: 'demo_txn_refund_001',
    },

    // ── RFQ booking (request for quote) ──
    {
      id: 'demo_booking_rfq',
      user_id: DEMO_CUSTOMER_UID,
      service_provider_id: DEMO_ARTISAN_UID,
      task_id: 'task_geyser_repair',
      task_name: 'Geyser Repair',
      scheduled_date: isoDate(7),
      scheduled_time: '11:00',
      created_at: TS,
      status: 'pending',
      cost: '0',
      description: 'Geyser burst — water everywhere. Need emergency repair.',
      user_confirmed: 'yes',
      artisan_confirmed: 'pending',
      reassigned_count: 0,
      service_on_location: true,
      provided_address: '101 Rivonia Rd, Sandton',
      user_lat: '-26.1076',
      user_lng: '28.0567',
      is_rfq: 'yes',
      rfq_reason: 'big_job',
      category_id: 'cat_plumbing',
      category_name: 'Plumbing',
      wallet_deducted: false,
      wallet_refunded: false,
    },
  ];

  for (const b of bookings) {
    await safeSet(db.collection('futureBookings').doc(b.id), b, `booking ${b.id}`);
  }
}

// ═══════════════════════════════════════════════════════════════
// 5. SEED TASK MANAGEMENT (order execution records)
// ═══════════════════════════════════════════════════════════════
async function seedTaskManagement() {
  console.log('\n📌 Seeding tasksManagement...');

  const tmDocs = [
    // ── Pending TM (linked to confirmed booking) ──
    {
      id: 'demo_tm_confirmed',
      orderNo: 'SQ15-2026-0001',
      accept: '1',
      cost: '500',
      creation_date: TS,
      future_booking_id: 'demo_booking_confirmed',
      scheduled_date: isoDate(1),
      scheduled_time: '14:30',
      payment: '',
      payment_status: 'paid',
      status: 'accepted',
      task_id: 'task_unblock_drain',
      user_id: DEMO_CUSTOMER_UID,
      service_provider_id: DEMO_ARTISAN_UID,
      user_comment: '',
      rating: '',
      description: 'Bathroom drain blocked completely',
      service_on_current_location: true,
      user_provided_address: '22 Oak Ave, Rosebank, Johannesburg',
      buying_material: false,
    },

    // ── Completed TM (linked to completed booking) ──
    {
      id: 'demo_tm_completed',
      orderNo: 'SQ15-2026-0002',
      accept: '1',
      cost: '650',
      creation_date: admin.firestore.Timestamp.fromDate(new Date(NOW.getTime() - 7 * 86400000)),
      completion_date: admin.firestore.Timestamp.fromDate(new Date(NOW.getTime() - 5 * 86400000)),
      closed_date: admin.firestore.Timestamp.fromDate(new Date(NOW.getTime() - 5 * 86400000)),
      future_booking_id: 'demo_booking_completed',
      scheduled_date: isoDate(-5),
      scheduled_time: '09:00',
      payment: 'wallet',
      payment_status: 'paid',
      status: 'completed',
      task_id: 'task_power_outlet',
      user_id: DEMO_CUSTOMER_UID,
      service_provider_id: DEMO_ARTISAN_UID,
      user_comment: 'Excellent work, very professional!',
      rating: '5',
      description: 'New power outlet in home office',
      service_on_current_location: true,
      user_provided_address: '8 Tech Park, Midrand',
      buying_material: false,
      image_urls: [],
    },

    // ── Pending TM (new, not yet accepted — for pending booking) ──
    {
      id: 'demo_tm_pending',
      orderNo: 'SQ15-2026-0003',
      accept: '',
      cost: '350',
      creation_date: TS,
      future_booking_id: 'demo_booking_pending',
      scheduled_date: isoDate(3),
      scheduled_time: '10:00',
      payment: '',
      payment_status: 'pending',
      status: 'pending',
      task_id: 'task_fix_tap',
      user_id: DEMO_CUSTOMER_UID,
      service_provider_id: DEMO_ARTISAN_UID,
      user_comment: '',
      rating: '',
      description: 'Kitchen tap has been dripping for 2 days',
      service_on_current_location: true,
      user_provided_address: '15 Main Rd, Sandton, Johannesburg',
      buying_material: false,
    },
  ];

  for (const tm of tmDocs) {
    await safeSet(db.collection('tasksManagement').doc(tm.id), tm, `TM ${tm.id}`);
  }
}

// ═══════════════════════════════════════════════════════════════
// 6. SEED CHAT MESSAGES
// ═══════════════════════════════════════════════════════════════
async function seedChat() {
  console.log('\n📌 Seeding chat messages...');

  const chatRef = db.collection('tasksManagement').doc('demo_tm_confirmed').collection('chat');

  const messages = [
    {
      sender_id: DEMO_CUSTOMER_UID,
      receiver_id: DEMO_ARTISAN_UID,
      message: 'Hi, the drain has been blocked since yesterday. Can you come earlier?',
      type: 'text',
      isRead: true,
      timestamp: admin.firestore.Timestamp.fromDate(new Date(NOW.getTime() - 3600000)),
    },
    {
      sender_id: DEMO_ARTISAN_UID,
      receiver_id: DEMO_CUSTOMER_UID,
      message: 'Good day! I can be there by 14:00. Will bring all necessary equipment.',
      type: 'text',
      isRead: true,
      timestamp: admin.firestore.Timestamp.fromDate(new Date(NOW.getTime() - 3000000)),
    },
    {
      sender_id: DEMO_CUSTOMER_UID,
      receiver_id: DEMO_ARTISAN_UID,
      message: 'Perfect, thank you! Gate code is 1234#',
      type: 'text',
      isRead: false,
      timestamp: admin.firestore.Timestamp.fromDate(new Date(NOW.getTime() - 2400000)),
    },
  ];

  for (let i = 0; i < messages.length; i++) {
    await safeSet(chatRef.doc(`demo_msg_${i}`), messages[i], `chat msg ${i}`);
  }

  // Active users
  const activeRef = db.collection('tasksManagement').doc('demo_tm_confirmed').collection('chatActiveUsers');
  await safeSet(activeRef.doc(DEMO_CUSTOMER_UID), { isActive: true }, 'chat active customer');
  await safeSet(activeRef.doc(DEMO_ARTISAN_UID), { isActive: false }, 'chat active artisan');
}

// ═══════════════════════════════════════════════════════════════
// 7. SEED TRANSACTION LOGS
// ═══════════════════════════════════════════════════════════════
async function seedTransactions() {
  console.log('\n📌 Seeding transaction logs...');

  const txns = [
    {
      id: 'demo_txn_wallet_topup',
      user_id: DEMO_CUSTOMER_UID,
      amount: 2000,
      type: 'wallet_topup',
      status: 'completed',
      payment_method: 'card',
      reference_id: 'payfast_ref_001',
      timestamp: admin.firestore.Timestamp.fromDate(new Date(NOW.getTime() - 10 * 86400000)),
      description: 'Wallet top-up via PayFast — R2,000',
    },
    {
      id: 'demo_txn_payment_001',
      user_id: DEMO_CUSTOMER_UID,
      amount: 650,
      type: 'payment',
      status: 'completed',
      booking_id: 'demo_booking_completed',
      task_management_id: 'demo_tm_completed',
      payment_method: 'wallet',
      timestamp: admin.firestore.Timestamp.fromDate(new Date(NOW.getTime() - 7 * 86400000)),
      description: 'Payment for Install Power Outlet',
    },
    {
      id: 'demo_txn_payment_002',
      user_id: DEMO_CUSTOMER_UID,
      amount: 500,
      type: 'payment',
      status: 'completed',
      booking_id: 'demo_booking_confirmed',
      task_management_id: 'demo_tm_confirmed',
      payment_method: 'wallet',
      timestamp: TS,
      description: 'Payment for Unblock Drain',
    },
    {
      id: 'demo_txn_refund_001',
      user_id: DEMO_CUSTOMER_UID,
      amount: 1800,
      type: 'refund',
      status: 'completed',
      booking_id: 'demo_booking_cancelled',
      payment_method: 'wallet',
      timestamp: admin.firestore.Timestamp.fromDate(new Date(NOW.getTime() - 2 * 86400000)),
      description: 'Refund for cancelled Paint Room booking',
    },
  ];

  for (const t of txns) {
    await safeSet(db.collection('transactionLogs').doc(t.id), t, `txn ${t.id}`);
  }
}

// ═══════════════════════════════════════════════════════════════
// 8. SEED NOTIFICATIONS
// ═══════════════════════════════════════════════════════════════
async function seedNotifications() {
  console.log('\n📌 Seeding notifications...');

  const notifs = [
    {
      id: 'demo_notif_001',
      title: 'Booking Confirmed',
      body: 'Your Unblock Drain booking for tomorrow at 14:30 has been confirmed by the artisan.',
      type: 'booking_confirmed',
      user_id: DEMO_CUSTOMER_UID,
      timestamp: TS,
      view: false,
    },
    {
      id: 'demo_notif_002',
      title: 'Job Completed',
      body: 'Your Install Power Outlet job has been marked as completed. Please rate your artisan!',
      type: 'job_completed',
      user_id: DEMO_CUSTOMER_UID,
      timestamp: admin.firestore.Timestamp.fromDate(new Date(NOW.getTime() - 5 * 86400000)),
      view: true,
    },
    {
      id: 'demo_notif_003',
      title: 'Refund Processed',
      body: 'R1,800.00 has been refunded to your wallet for the cancelled Paint Room booking.',
      type: 'refund',
      user_id: DEMO_CUSTOMER_UID,
      timestamp: admin.firestore.Timestamp.fromDate(new Date(NOW.getTime() - 2 * 86400000)),
      view: true,
    },
    {
      id: 'demo_notif_artisan_001',
      title: 'New Job Request',
      body: 'You have a new Fix Leaking Tap job request for ' + isoDate(3) + '. Tap to review.',
      type: 'new_job',
      user_id: DEMO_ARTISAN_UID,
      timestamp: TS,
      view: false,
    },
  ];

  for (const n of notifs) {
    await safeSet(db.collection('notifications').doc(n.id), n, `notif ${n.id}`);
  }
}

// ═══════════════════════════════════════════════════════════════
// 9. SEED APP CONFIG (BNPL providers, general settings)
// ═══════════════════════════════════════════════════════════════
async function seedAppConfig() {
  console.log('\n📌 Seeding app_config (BNPL providers + settings)...');

  const bnplConfigs = [
    {
      doc: 'bnpl_payJustNow',
      data: {
        api_key: 'pjn_demo_key_sandbox_001',
        confirm_url: 'https://square15.co.za/bnpl/payJustNow/confirm',
        cancel_url: 'https://square15.co.za/bnpl/payJustNow/cancel',
        merchant_fee_percent: 5.0,
        enabled: true,
        use_sandbox: true,
        provider: 'payJustNow',
        provider_name: 'PayJustNow',
        updated_at: NOW.toISOString(),
      },
    },
    {
      doc: 'bnpl_moreTyme',
      data: {
        api_key: 'mt_demo_key_sandbox_001',
        confirm_url: 'https://square15.co.za/bnpl/moreTyme/confirm',
        cancel_url: 'https://square15.co.za/bnpl/moreTyme/cancel',
        merchant_fee_percent: 4.5,
        enabled: true,
        use_sandbox: true,
        provider: 'moreTyme',
        provider_name: 'MoreTyme',
        updated_at: NOW.toISOString(),
      },
    },
    {
      doc: 'bnpl_happyPay',
      data: {
        api_key: 'hp_demo_key_sandbox_001',
        confirm_url: 'https://square15.co.za/bnpl/happyPay/confirm',
        cancel_url: 'https://square15.co.za/bnpl/happyPay/cancel',
        merchant_fee_percent: 4.0,
        enabled: true,
        use_sandbox: true,
        provider: 'happyPay',
        provider_name: 'Happy Pay',
        updated_at: NOW.toISOString(),
      },
    },
    {
      doc: 'bnpl_mobicred',
      data: {
        api_key: 'mob_demo_key_sandbox_001',
        confirm_url: 'https://square15.co.za/bnpl/mobicred/confirm',
        cancel_url: 'https://square15.co.za/bnpl/mobicred/cancel',
        merchant_fee_percent: 6.0,
        enabled: true,
        use_sandbox: true,
        provider: 'mobicred',
        provider_name: 'Mobicred',
        updated_at: NOW.toISOString(),
      },
    },
  ];

  for (const cfg of bnplConfigs) {
    await safeSet(db.collection('app_config').doc(cfg.doc), cfg.data, `config ${cfg.doc}`);
  }

  // Order counter
  await safeSet(db.collection('metadata').doc('counters'), {
    order_counter: 3,
  }, 'order counter');
}

// ═══════════════════════════════════════════════════════════════
// 10. SEED BNPL ORDERS (demo)
// ═══════════════════════════════════════════════════════════════
async function seedBnplOrders() {
  console.log('\n📌 Seeding BNPL demo orders...');

  const orders = [
    {
      id: 'demo_bnpl_order_001',
      provider: 'payJustNow',
      provider_name: 'PayJustNow',
      user_id: DEMO_CUSTOMER_UID,
      amount: '1200',
      status: 'approved',
      token: 'pjn_tok_demo_001',
      booking_id: '',
      created_at: new Date(NOW.getTime() - 3 * 86400000).toISOString(),
      updated_at: new Date(NOW.getTime() - 3 * 86400000).toISOString(),
    },
    {
      id: 'demo_bnpl_order_002',
      provider: 'moreTyme',
      provider_name: 'MoreTyme',
      user_id: DEMO_CUSTOMER_UID,
      amount: '800',
      status: 'pending',
      token: 'mt_tok_demo_001',
      booking_id: '',
      created_at: NOW.toISOString(),
      updated_at: NOW.toISOString(),
    },
  ];

  for (const o of orders) {
    await safeSet(db.collection('bnpl_orders').doc(o.id), o, `bnpl order ${o.id}`);
  }
}

// ═══════════════════════════════════════════════════════════════
// 11. SEED REVIEWS
// ═══════════════════════════════════════════════════════════════
async function seedReviews() {
  console.log('\n📌 Seeding artisan reviews...');

  await safeSet(
    db.collection('serviceProvider').doc(DEMO_ARTISAN_UID).collection('reviews').doc('demo_review_001'),
    {
      rating: 5,
      comment: 'Excellent work! Very professional and on time.',
      reviewer_id: DEMO_CUSTOMER_UID,
      reviewer_name: 'Demo Customer',
      task_management_id: 'demo_tm_completed',
      timestamp: admin.firestore.Timestamp.fromDate(new Date(NOW.getTime() - 5 * 86400000)),
    },
    'artisan review'
  );
}

// ═══════════════════════════════════════════════════════════════
// 12. SEED CORPORATE PARTNER
// ═══════════════════════════════════════════════════════════════
async function seedPartner() {
  console.log('\n📌 Seeding corporate partner...');

  await safeSet(db.collection('corporate_partners').doc(DEMO_PARTNER_ID), {
    id: DEMO_PARTNER_ID,
    company_name: 'Demo Property Group',
    contact_name: 'John Demo',
    email: 'john@demoproperty.co.za',
    phone: '0821112222',
    referral_code: 'DEMO2026',
    commission_tier: 'silver',
    commission_rate: 7.5,
    peak_tier: 'silver',
    underperform_streak: 0,
    total_earned: 150.00,
    pending_payout: 48.75,
    paid_out: 101.25,
    status: 'active',
    buildings: ['Demo Towers', 'Demo Heights'],
    total_referrals: 3,
    created_at: TS,
    updated_at: TS,
    payout_method: 'bank_transfer',
    bank_name: 'FNB',
    account_number: '62000000001',
    branch_code: '250655',
  }, 'corporate partner');
}

// ═══════════════════════════════════════════════════════════════
// 13. SEED PROMO CODES
// ═══════════════════════════════════════════════════════════════
async function seedPromos() {
  console.log('\n📌 Seeding promo codes...');

  await safeSet(db.collection('promo_codes').doc('demo_promo_001'), {
    code: 'WELCOME50',
    discount_type: 'fixed_amount',
    discount_value: 50,
    max_uses: 100,
    used_count: 5,
    per_user_limit: 1,
    min_job_value: 200,
    valid_categories: [],
    start_date: isoDate(-30),
    end_date: isoDate(30),
    status: 'active',
    promo_type: 'campaign',
    description: 'Welcome discount — R50 off your first booking',
    created_by: DEMO_ADMIN_UID,
    created_at: TS,
  }, 'promo code');
}

// ═══════════════════════════════════════════════════════════════
// 14. SEED LOYALTY POINTS
// ═══════════════════════════════════════════════════════════════
async function seedLoyalty() {
  console.log('\n📌 Seeding loyalty points...');

  await safeSet(db.collection('loyalty_points').doc(DEMO_CUSTOMER_UID), {
    user_id: DEMO_CUSTOMER_UID,
    total_points: 150,
    lifetime_points: 200,
    tier: 'member',
    updated_at: TS,
  }, 'loyalty points');

  await safeSet(db.collection('loyalty_points_transactions').doc('demo_lpt_001'), {
    user_id: DEMO_CUSTOMER_UID,
    points: 100,
    type: 'job_completed',
    reference_id: 'demo_tm_completed',
    description: 'Points earned for Install Power Outlet job',
    created_at: admin.firestore.Timestamp.fromDate(new Date(NOW.getTime() - 5 * 86400000)),
  }, 'loyalty txn');

  await safeSet(db.collection('loyalty_points_transactions').doc('demo_lpt_002'), {
    user_id: DEMO_CUSTOMER_UID,
    points: -50,
    type: 'redemption',
    reference_id: '',
    description: 'Redeemed 50 points for R25 wallet credit',
    created_at: admin.firestore.Timestamp.fromDate(new Date(NOW.getTime() - 2 * 86400000)),
  }, 'loyalty redeem txn');
}

// ═══════════════════════════════════════════════════════════════
// 15. SEED FINANCE REQUESTS
// ═══════════════════════════════════════════════════════════════
async function seedFinance() {
  console.log('\n📌 Seeding finance requests...');

  await safeSet(db.collection('finance_requests').doc('demo_fin_001'), {
    type: 'refund',
    status: 'approved',
    amount: 1800,
    target_user_id: DEMO_CUSTOMER_UID,
    reason: 'Artisan no-show on Paint Room booking',
    booking_id: 'demo_booking_cancelled',
    requested_by: 'system',
    approved_by: DEMO_ADMIN_UID,
    created_at: admin.firestore.Timestamp.fromDate(new Date(NOW.getTime() - 2 * 86400000)),
    approved_at: admin.firestore.Timestamp.fromDate(new Date(NOW.getTime() - 2 * 86400000)),
  }, 'finance request');
}

// ═══════════════════════════════════════════════════════════════
// 16. SEED SUPPORT CASE & COMPLAINTS
// ═══════════════════════════════════════════════════════════════
async function seedSupportCases() {
  console.log('\n📌 Seeding support cases...');

  await safeSet(db.collection('assistant_cases').doc('demo_case_001'), {
    case_id: 'demo_case_001',
    user_id: DEMO_CUSTOMER_UID,
    case_type: 'complaint',
    status: 'resolved',
    description: 'Artisan arrived 30 minutes late for appointment',
    related_booking_id: 'demo_booking_completed',
    created_at: admin.firestore.Timestamp.fromDate(new Date(NOW.getTime() - 5 * 86400000)),
    resolved_at: admin.firestore.Timestamp.fromDate(new Date(NOW.getTime() - 4 * 86400000)),
    assigned_to: DEMO_ADMIN_UID,
  }, 'support case');

  await safeSet(db.collection('complaints').doc('demo_complaint_001'), {
    user_id: DEMO_CUSTOMER_UID,
    service_provider_id: DEMO_ARTISAN_UID,
    reason: 'Arrived late, but overall good service',
    images: [],
    status: 'resolved',
    created_at: admin.firestore.Timestamp.fromDate(new Date(NOW.getTime() - 5 * 86400000)),
  }, 'complaint');
}

// ═══════════════════════════════════════════════════════════════
// FLOW VALIDATION
// ═══════════════════════════════════════════════════════════════

async function validateFlow(label, fn) {
  try {
    const result = await fn();
    flowResults.push({ flow: label, status: '✅ PASS', detail: result || 'OK' });
  } catch (e) {
    flowResults.push({ flow: label, status: '❌ FAIL', detail: e.message });
  }
}

async function runFlowTests() {
  console.log('\n\n══════════════════════════════════════════');
  console.log('   FLOW VALIDATION TESTS');
  console.log('══════════════════════════════════════════\n');

  // ── 1. User profile exists & has wallet balance ──
  await validateFlow('1. Customer profile & wallet', async () => {
    const snap = await db.collection('users').doc(DEMO_CUSTOMER_UID).get();
    if (!snap.exists) throw new Error('Customer doc missing');
    const d = snap.data();
    if (!d.name || !d.email) throw new Error('Missing name/email');
    if (parseFloat(d.balance) < 0) throw new Error('Negative balance');
    return `name=${d.name}, balance=R${d.balance}`;
  });

  // ── 2. Artisan profile exists with service provider doc ──
  await validateFlow('2. Artisan profile (users + serviceProvider)', async () => {
    const userSnap = await db.collection('users').doc(DEMO_ARTISAN_UID).get();
    const spSnap = await db.collection('serviceProvider').doc(DEMO_ARTISAN_UID).get();
    if (!userSnap.exists) throw new Error('Artisan user doc missing');
    if (!spSnap.exists) throw new Error('serviceProvider doc missing');
    const sp = spSnap.data();
    if (sp.status !== 'publish') throw new Error(`SP status=${sp.status}, expected publish`);
    return `${sp.name}, category=${sp.mainCategory}, verified=${sp.isVerified}`;
  });

  // ── 3. Categories exist ──
  await validateFlow('3. Categories loaded', async () => {
    const snap = await db.collection('categories').where('status', '==', 'active').get();
    if (snap.empty) throw new Error('No active categories');
    return `${snap.size} active categories`;
  });

  // ── 4. Tasks exist for each category ──
  await validateFlow('4. Tasks linked to categories', async () => {
    const snap = await db.collection('tasks').where('status', '==', 'active').get();
    if (snap.empty) throw new Error('No active tasks');
    const catIds = new Set(snap.docs.map(d => d.data().categoryId));
    return `${snap.size} active tasks across ${catIds.size} categories`;
  });

  // ── 5. Booking lifecycle: pending → confirmed → completed → cancelled ──
  await validateFlow('5. Booking lifecycle (all states)', async () => {
    const states = ['pending', 'confirmed', 'completed', 'cancelled'];
    const found = [];
    for (const s of states) {
      const q = await db.collection('futureBookings').where('status', '==', s).limit(1).get();
      if (q.empty) throw new Error(`No booking with status=${s}`);
      found.push(s);
    }
    return `All states present: ${found.join(', ')}`;
  });

  // ── 6. RFQ booking exists ──
  await validateFlow('6. RFQ booking flow', async () => {
    const q = await db.collection('futureBookings').where('is_rfq', '==', 'yes').limit(1).get();
    if (q.empty) throw new Error('No RFQ bookings');
    const d = q.docs[0].data();
    return `RFQ: ${d.task_name}, reason=${d.rfq_reason}`;
  });

  // ── 7. Task management linked to bookings ──
  await validateFlow('7. TaskManagement ↔ Booking link', async () => {
    const tmSnap = await db.collection('tasksManagement').doc('demo_tm_confirmed').get();
    if (!tmSnap.exists) throw new Error('TM doc missing');
    const tm = tmSnap.data();
    if (tm.future_booking_id !== 'demo_booking_confirmed') throw new Error('Booking link broken');
    const bkSnap = await db.collection('futureBookings').doc(tm.future_booking_id).get();
    if (!bkSnap.exists) throw new Error('Linked booking missing');
    return `TM ${tm.orderNo} → Booking ${tm.future_booking_id} (status=${tm.status})`;
  });

  // ── 8. Chat messages exist for TM ──
  await validateFlow('8. Chat messages (customer ↔ artisan)', async () => {
    const chatSnap = await db.collection('tasksManagement').doc('demo_tm_confirmed')
      .collection('chat').orderBy('timestamp').get();
    if (chatSnap.empty) throw new Error('No chat messages');
    const senders = new Set(chatSnap.docs.map(d => d.data().sender_id));
    if (senders.size < 2) throw new Error('Only one party chatted');
    return `${chatSnap.size} messages from ${senders.size} participants`;
  });

  // ── 9. Transaction logs exist ──
  await validateFlow('9. Transaction logs (payment + refund)', async () => {
    const paySnap = await db.collection('transactionLogs').where('type', '==', 'payment').limit(1).get();
    const refSnap = await db.collection('transactionLogs').where('type', '==', 'refund').limit(1).get();
    if (paySnap.empty) throw new Error('No payment transactions');
    if (refSnap.empty) throw new Error('No refund transactions');
    return `Payments: ${paySnap.size}+, Refunds: ${refSnap.size}+`;
  });

  // ── 10. Wallet refund on cancelled booking ──
  await validateFlow('10. Wallet refund on cancellation', async () => {
    const snap = await db.collection('futureBookings').doc('demo_booking_cancelled').get();
    if (!snap.exists) throw new Error('Cancelled booking missing');
    const d = snap.data();
    if (!d.wallet_refunded) throw new Error('wallet_refunded is false');
    if (d.wallet_refund_amount !== 1800) throw new Error(`Refund amount=${d.wallet_refund_amount}, expected 1800`);
    return `Refunded R${d.wallet_refund_amount}, txn=${d.wallet_refund_txn_id}`;
  });

  // ── 11. Notifications exist ──
  await validateFlow('11. Notifications (read + unread)', async () => {
    const custNotifs = await db.collection('notifications')
      .where('user_id', '==', DEMO_CUSTOMER_UID).get();
    if (custNotifs.empty) throw new Error('No customer notifications');
    const unread = custNotifs.docs.filter(d => !d.data().view).length;
    return `${custNotifs.size} notifications (${unread} unread)`;
  });

  // ── 12. BNPL config exists for all 4 providers ──
  await validateFlow('12. BNPL config (all 4 providers)', async () => {
    const providers = ['bnpl_payJustNow', 'bnpl_moreTyme', 'bnpl_happyPay', 'bnpl_mobicred'];
    const results = [];
    for (const doc of providers) {
      const snap = await db.collection('app_config').doc(doc).get();
      if (!snap.exists) throw new Error(`Config ${doc} missing`);
      const d = snap.data();
      if (!d.api_key) throw new Error(`${doc} has no api_key`);
      results.push(`${d.provider_name}: ${d.enabled ? 'ON' : 'OFF'}`);
    }
    return results.join(', ');
  });

  // ── 13. BNPL orders exist ──
  await validateFlow('13. BNPL orders', async () => {
    const snap = await db.collection('bnpl_orders').get();
    if (snap.empty) throw new Error('No BNPL orders');
    const statuses = snap.docs.map(d => `${d.data().provider_name}:${d.data().status}`);
    return statuses.join(', ');
  });

  // ── 14. Artisan review exists ──
  await validateFlow('14. Artisan reviews', async () => {
    const snap = await db.collection('serviceProvider').doc(DEMO_ARTISAN_UID)
      .collection('reviews').get();
    if (snap.empty) throw new Error('No reviews');
    const avg = snap.docs.reduce((sum, d) => sum + d.data().rating, 0) / snap.size;
    return `${snap.size} reviews, avg rating=${avg.toFixed(1)}`;
  });

  // ── 15. Corporate partner & referral ──
  await validateFlow('15. Corporate partner', async () => {
    const snap = await db.collection('corporate_partners').doc(DEMO_PARTNER_ID).get();
    if (!snap.exists) throw new Error('Partner doc missing');
    const d = snap.data();
    return `${d.company_name}, code=${d.referral_code}, tier=${d.commission_tier}, earned=R${d.total_earned}`;
  });

  // ── 16. Promo codes ──
  await validateFlow('16. Promo codes', async () => {
    const snap = await db.collection('promo_codes').where('status', '==', 'active').limit(1).get();
    if (snap.empty) throw new Error('No active promo codes');
    const d = snap.docs[0].data();
    return `${d.code}: ${d.discount_type}=${d.discount_value}, used=${d.used_count}/${d.max_uses}`;
  });

  // ── 17. Loyalty points ──
  await validateFlow('17. Loyalty points', async () => {
    const snap = await db.collection('loyalty_points').doc(DEMO_CUSTOMER_UID).get();
    if (!snap.exists) throw new Error('Loyalty doc missing');
    const d = snap.data();
    if (d.total_points <= 0) throw new Error(`Points=${d.total_points}`);
    return `${d.total_points} points, tier=${d.tier}, lifetime=${d.lifetime_points}`;
  });

  // ── 18. Finance approval system ──
  await validateFlow('18. Finance approval', async () => {
    const snap = await db.collection('finance_requests').where('status', '==', 'approved').limit(1).get();
    if (snap.empty) throw new Error('No approved finance requests');
    const d = snap.docs[0].data();
    return `${d.type}: R${d.amount}, approved_by=${d.approved_by}`;
  });

  // ── 19. Support cases ──
  await validateFlow('19. Support cases', async () => {
    const snap = await db.collection('assistant_cases').limit(1).get();
    if (snap.empty) throw new Error('No support cases');
    const d = snap.docs[0].data();
    return `${d.case_type}: ${d.status}`;
  });

  // ── 20. Payment → Booking → TM → Review chain ──
  await validateFlow('20. Full order chain (Payment→Booking→TM→Review)', async () => {
    // Start from transaction
    const txSnap = await db.collection('transactionLogs').doc('demo_txn_payment_001').get();
    if (!txSnap.exists) throw new Error('Transaction missing');
    const tx = txSnap.data();

    // Follow to booking
    const bkSnap = await db.collection('futureBookings').doc(tx.booking_id).get();
    if (!bkSnap.exists) throw new Error('Booking missing from txn link');
    const bk = bkSnap.data();

    // Follow to TM
    const tmSnap = await db.collection('tasksManagement').doc(tx.task_management_id).get();
    if (!tmSnap.exists) throw new Error('TM missing from txn link');
    const tm = tmSnap.data();

    // Check review exists for this TM
    const revSnap = await db.collection('serviceProvider').doc(bk.service_provider_id)
      .collection('reviews').where('task_management_id', '==', tx.task_management_id).get();

    return `Txn(R${tx.amount}) → Booking(${bk.status}) → TM(${tm.status}) → ${revSnap.size} review(s)`;
  });

  // ── 21. Booking with wallet deduction guard ──
  await validateFlow('21. Wallet deduction guard', async () => {
    const snap = await db.collection('futureBookings').doc('demo_booking_confirmed').get();
    const d = snap.data();
    if (!d.wallet_deducted) throw new Error('wallet_deducted is false on paid booking');
    if (!d.wallet_deducted_amount) throw new Error('wallet_deducted_amount is empty');
    return `Deducted R${d.wallet_deducted_amount}, refunded=${d.wallet_refunded}`;
  });

  // ── 22. Artisan has pending job to accept ──
  await validateFlow('22. Artisan pending job acceptance', async () => {
    const q = await db.collection('tasksManagement')
      .where('service_provider_id', '==', DEMO_ARTISAN_UID)
      .where('status', '==', 'pending')
      .get();
    if (q.empty) throw new Error('No pending jobs for artisan');
    return `${q.size} pending job(s) awaiting artisan acceptance`;
  });

  // ── 23. Order counter exists ──
  await validateFlow('23. Order counter (metadata)', async () => {
    const snap = await db.collection('metadata').doc('counters').get();
    if (!snap.exists) throw new Error('Counters doc missing');
    const d = snap.data();
    if (typeof d.order_counter !== 'number') throw new Error('order_counter is not a number');
    return `Current order counter: ${d.order_counter}`;
  });

  // ── Print results ──
  console.log('\n══════════════════════════════════════════');
  console.log('   RESULTS');
  console.log('══════════════════════════════════════════\n');

  let passed = 0; let failed = 0;
  for (const r of flowResults) {
    console.log(`${r.status}  ${r.flow}`);
    if (r.detail) console.log(`       └─ ${r.detail}`);
    if (r.status.includes('PASS')) passed++; else failed++;
  }

  console.log(`\n────────────────────────────────────────`);
  console.log(`  ${passed} passed, ${failed} failed out of ${flowResults.length} tests`);
  console.log(`────────────────────────────────────────\n`);

  return failed;
}

// ═══════════════════════════════════════════════════════════════
// MAIN
// ═══════════════════════════════════════════════════════════════
async function main() {
  console.log('════════════════════════════════════════════════════════');
  console.log('  Square 15 — Full Demo Seeder & Flow Validator');
  console.log('════════════════════════════════════════════════════════');

  // Seed all data
  await seedUsers();
  await seedServiceProvider();
  await seedCategories();
  await seedBookings();
  await seedTaskManagement();
  await seedChat();
  await seedTransactions();
  await seedNotifications();
  await seedAppConfig();
  await seedBnplOrders();
  await seedReviews();
  await seedPartner();
  await seedPromos();
  await seedLoyalty();
  await seedFinance();
  await seedSupportCases();

  console.log(`\n✅ Seeded ${created} documents (${errors} errors)`);

  // Validate all flows
  const failures = await runFlowTests();

  process.exit(failures > 0 ? 1 : 0);
}

main().catch(e => {
  console.error('Fatal:', e);
  process.exit(1);
});
