// CI only: answers the backend's Gemini calls with canned replies, so the real `ai` function (its
// prompts, allowances, holds and counting) runs end to end on the Firebase emulators without a key
// or any cost. Loaded into the functions emulator with NODE_OPTIONS="--require <this file>"; every
// other request goes to the real fetch untouched.
//
// Which feature asked is read from the response schema the backend sends. The replies follow what
// the request carried: the person's own instructions ("CAPITAL LETTERS") and a follow-up's words
// ("remove the coffee") change the answer, so the app's tests can see they reached the AI.
"use strict";

const realFetch = globalThis.fetch;
let calls = 0;

function reply(json) {
  return new Response(JSON.stringify({
    candidates: [{ finishReason: "STOP", content: { parts: [{ text: JSON.stringify(json) }] } }],
    usageMetadata: { promptTokenCount: 120, candidatesTokenCount: 60, thoughtsTokenCount: 0 },
  }), { status: 200, headers: { "Content-Type": "application/json" } });
}

function day(d) {
  return d.toISOString().slice(0, 10);
}

globalThis.fetch = async function (url, init) {
  if (typeof url !== "string" || !url.includes("generativelanguage.googleapis.com")) return realFetch(url, init);
  calls++;
  const body = JSON.parse(init.body);
  const parts = body.contents?.[0]?.parts ?? [];
  const prompt = parts.map((p) => p.text ?? "").join("\n");
  const props = Object.keys(body.generationConfig?.responseSchema?.properties ?? {});
  // The own-instructions part may sit in another content or part than the prompt: look at it all
  const upper = init.body.includes("CAPITAL LETTERS");
  const name = (s) => (upper ? s.toUpperCase() : s);
  console.log(`[fake-gemini] call ${calls}: ${props.join(",")} images=${parts.filter((p) => p.inlineData?.mimeType === "image/jpeg").length}`);

  if (props.includes("purchases")) {
    return reply({
      transcript: null,
      purchases: [
        { bought: true, listName: "Gas fill-up", category: "Car", store: null, date: null,
          items: [{ name: name("Gas"), quantity: 1, unit: null, unitPrice: null, totalPrice: 40, currency: null }] },
        { bought: true, listName: "Groceries", category: "Groceries", store: "Spinneys", date: null,
          items: [{ name: name("Milk"), quantity: 1, unit: null, unitPrice: null, totalPrice: 3.5, currency: null }] },
      ],
    });
  }
  if (props.includes("startDate")) {
    const now = new Date();
    const start = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 1, 1));
    const end = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 0));
    return reply({ transcript: null, startDate: day(start), endDate: day(end), focus: [], category: null, store: null, item: null, question: null });
  }
  if (props.includes("summary")) {
    return reply({
      title: "Last month's spending",
      summary: "You spent a little more than the month before; groceries were most of it.",
      sections: [{ kind: "prices", heading: "Gas went up", body: "Each fill-up cost more.", points: ["Four fill-ups at Total"] }],
      tips: ["Buy milk at Carrefour."],
    });
  }
  if (props.includes("items")) {
    // A receipt in lira; a follow-up asking to remove the coffee leaves it out
    const lines = [
      { name: name("Tomatoes"), listItem: null, quantity: 1.2, unit: "kg", unitPrice: 120000, totalPrice: 144000 },
      { name: name("Labneh"), listItem: null, quantity: 1, unit: null, unitPrice: 295000, totalPrice: 295000 },
      { name: name("Coffee"), listItem: null, quantity: 1, unit: null, unitPrice: 815000, totalPrice: 815000 },
    ];
    const followUp = /remove the coffee/i.test(prompt);
    return reply({
      transcript: null, store: "Spinneys", date: null, currency: "LBP", listName: "Receipt", category: "Groceries", existingList: null,
      items: followUp ? lines.filter((l) => !/coffee/i.test(l.name)) : lines,
    });
  }
  return new Response("{}", { status: 400 });
};
