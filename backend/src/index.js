const express = require("express");
const mongoose = require("mongoose");
const client = require("prom-client");

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 5000;
const MONGO_URI = process.env.MONGO_URI;

// ---- Prometheus metrics ----
const register = new client.Registry();
client.collectDefaultMetrics({ register }); // memory, CPU, event loop lag, GC

const httpRequests = new client.Counter({
  name: "http_requests_total",
  help: "Total HTTP requests",
  labelNames: ["method", "route", "status"],
  registers: [register],
});

const httpDuration = new client.Histogram({
  name: "http_request_duration_seconds",
  help: "Request latency in seconds",
  labelNames: ["method", "route", "status"],
  buckets: [0.05, 0.1, 0.3, 0.5, 1, 2],
  registers: [register],
});

const itemsCreated = new client.Counter({
  name: "items_created_total",
  help: "Total items created",
  registers: [register],
});

// Record every request's count and duration
app.use((req, res, next) => {
  const end = httpDuration.startTimer();
  res.on("finish", () => {
    const route = req.route ? req.baseUrl + req.route.path : "unmatched";
    const labels = { method: req.method, route, status: res.statusCode };
    httpRequests.inc(labels);
    end(labels);
  });
  next();
});

// ---- Database model ----
const Item = mongoose.model(
  "Item",
  new mongoose.Schema({ name: String }, { timestamps: true }),
);

// ---- Routes ----
app.get("/api/health", (req, res) => {
  res.json({ status: "ok", db: mongoose.connection.readyState === 1 });
});

app.get("/api/items", async (req, res) => {
  const items = await Item.find().sort({ createdAt: -1 });
  res.json(items);
});

app.post("/api/items", async (req, res) => {
  const item = await Item.create({ name: req.body.name });
  itemsCreated.inc();
  res.status(201).json(item);
});

app.get("/metrics", async (req, res) => {
  res.set("Content-Type", register.contentType);
  res.end(await register.metrics());
});

// ---- Start: connect to Mongo, insert sample data, then listen ----
mongoose
  .connect(MONGO_URI)
  .then(async () => {
    console.log("Connected to MongoDB");
    if ((await Item.countDocuments()) === 0) {
      await Item.insertMany([
        { name: "Sample item 1" },
        { name: "Sample item 2" },
      ]);
      console.log("Inserted sample data");
    }
    app.listen(PORT, () => console.log(`API listening on port ${PORT}`));
  })
  .catch((err) => {
    console.error("MongoDB connection failed:", err.message);
    process.exit(1);
  });
