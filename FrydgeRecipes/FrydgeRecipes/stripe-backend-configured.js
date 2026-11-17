// Example Node.js backend for Stripe PaymentIntents
// Updated with your publishable key

const express = require('express');
const stripe = require('stripe')(process.env.STRIPE_SECRET_KEY);
const cors = require('cors');
const app = express();

app.use(express.json());
app.use(cors());

// Health check
app.get('/', (req, res) => {
  res.json({ 
    status: 'ok', 
    message: 'Stripe backend is running',
    timestamp: new Date().toISOString()
  });
});

app.get('/health', (req, res) => {
  res.json({ status: 'healthy' });
});

// Create a PaymentIntent
app.post('/create-payment-intent', async (req, res) => {
  try {
    const { amount, currency, metadata } = req.body;

    console.log(`Creating PaymentIntent for ${currency.toUpperCase()} ${amount / 100}`);

    // Create a customer (optional but recommended)
    const customer = await stripe.customers.create({
      metadata: metadata || {}
    });

    // Create ephemeral key for customer
    const ephemeralKey = await stripe.ephemeralKeys.create(
      { customer: customer.id },
      { apiVersion: '2024-11-20.acacia' }
    );

    // Create PaymentIntent
    const paymentIntent = await stripe.paymentIntents.create({
      amount: amount, // Amount in cents
      currency: currency || 'nzd',
      customer: customer.id,
      metadata: metadata || {},
      automatic_payment_methods: {
        enabled: true,
      },
    });

    console.log(`✅ PaymentIntent created: ${paymentIntent.id}`);

    res.json({
      clientSecret: paymentIntent.client_secret,
      ephemeralKey: ephemeralKey.secret,
      customerId: customer.id,
      publishableKey: process.env.STRIPE_PUBLISHABLE_KEY || 'pk_test_51TSViXCVYZKUKvUzJnn2qkhypIB7txxKzub2bZylpgmKyLJ6WCckN7iyITlSRoLW4uAcrWadY7TzFbzCZxs6c2ye00PHo3E4tG'
    });
  } catch (error) {
    console.error('❌ Error creating PaymentIntent:', error.message);
    res.status(500).json({ error: error.message });
  }
});

// Create connection token for Tap to Pay
app.post('/connection-token', async (req, res) => {
  try {
    const token = await stripe.terminal.connectionTokens.create();
    res.json({ secret: token.secret });
  } catch (error) {
    console.error('❌ Error creating connection token:', error.message);
    res.status(500).json({ error: error.message });
  }
});

// Webhook endpoint for payment confirmation
app.post('/webhook', express.raw({type: 'application/json'}), async (req, res) => {
  const sig = req.headers['stripe-signature'];
  const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET;

  if (!webhookSecret) {
    console.warn('⚠️  Webhook secret not set, skipping signature verification');
    return res.json({ received: true });
  }

  let event;
  try {
    event = stripe.webhooks.constructEvent(req.body, sig, webhookSecret);
  } catch (err) {
    console.error('⚠️  Webhook signature verification failed:', err.message);
    return res.status(400).send(`Webhook Error: ${err.message}`);
  }

  // Handle the event
  switch (event.type) {
    case 'payment_intent.succeeded':
      const paymentIntent = event.data.object;
      console.log('✅ Payment succeeded:', paymentIntent.id);
      // TODO: Update your database, send confirmation email, etc.
      break;
    case 'payment_intent.payment_failed':
      console.log('❌ Payment failed:', event.data.object.id);
      break;
    case 'charge.succeeded':
      console.log('💰 Charge succeeded:', event.data.object.id);
      break;
    default:
      console.log(`ℹ️  Unhandled event type ${event.type}`);
  }

  res.json({ received: true });
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log('🚀 Stripe backend running on port', PORT);
  console.log('');
  console.log('Configuration:');
  console.log('  Secret Key:', process.env.STRIPE_SECRET_KEY ? '✅ Set' : '❌ Missing');
  console.log('  Publishable Key:', process.env.STRIPE_PUBLISHABLE_KEY ? '✅ Set' : '⚠️  Using default');
  console.log('  Webhook Secret:', process.env.STRIPE_WEBHOOK_SECRET ? '✅ Set' : '⚠️  Not set (optional for testing)');
  console.log('');
  console.log('Endpoints:');
  console.log(`  POST http://localhost:${PORT}/create-payment-intent`);
  console.log(`  POST http://localhost:${PORT}/connection-token`);
  console.log(`  POST http://localhost:${PORT}/webhook`);
  console.log('');
  console.log('Ready to accept payments! 💳');
});

// Environment variables needed:
// STRIPE_SECRET_KEY=sk_test_... (REQUIRED - get from https://dashboard.stripe.com/test/apikeys)
// STRIPE_PUBLISHABLE_KEY=pk_test_... (optional - defaults to your key)
// STRIPE_WEBHOOK_SECRET=whsec_... (optional - for production webhooks)
// PORT=3000 (optional - defaults to 3000)
