import { useEffect, useState } from "react";

export default function App() {
  const [items, setItems] = useState([]);
  const [name, setName] = useState("");

  const load = async () => {
    const res = await fetch("/api/items");
    setItems(await res.json());
  };

  useEffect(() => {
    load();
  }, []);

  const addItem = async () => {
    if (!name.trim()) return;
    await fetch("/api/items", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name }),
    });
    setName("");
    load();
  };

  return (
    <main
      style={{ maxWidth: 480, margin: "40px auto", fontFamily: "sans-serif" }}
    >
      <h1>3-Tier App</h1>
      <input
        value={name}
        onChange={(e) => setName(e.target.value)}
        placeholder="New item"
      />
      <button onClick={addItem}>Add</button>
      <ul>
        {items.map((i) => (
          <li key={i._id}>{i.name}</li>
        ))}
      </ul>
    </main>
  );
}
