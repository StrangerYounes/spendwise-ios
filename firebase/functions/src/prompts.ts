// What each AI feature asks Gemini, and how. Plain functions so they can be unit tested.
//
// The phone sends only what a request needs: its typed text, voice note or photo, the names of its
// categories, stores, items and open lists, and for reports the prepared figures. Nothing here
// knows who the person is; the account is used only to count the allowance (index.ts).

export type Feature = "quickAdd" | "receipt" | "analysisRequest" | "analysisReport";

export const FEATURES: Feature[] = ["quickAdd", "receipt", "analysisRequest", "analysisReport"];

/** How one kind of request is sent. If Google renames or retires a model, change it here. */
export interface ModelConfig {
  model: string;
  maxOutputTokens: number;
  timeoutMs: number;
  /** "minimal" for extraction; thinking tokens are billed as output tokens. */
  thinkingLevel: string;
}

export const FAST_MODEL = "gemini-3.5-flash-lite";
// gemini-3.5-flash is deprecated (Google serves it as 3.6). Low thinking: on a 3-month report it wrote
// the most specific report of the options tried (store-by-store price gaps) at ~4¢, against ~5.5¢ for
// 3.5 Flash on medium; Flash-Lite cost ~1¢ but its tips went generic (FEATURES.md §5.0, 21 Oct)
export const REASONING_MODEL = "gemini-3.6-flash";

export const MODELS: Record<Feature, ModelConfig> = {
  quickAdd: { model: FAST_MODEL, maxOutputTokens: 2048, timeoutMs: 30_000, thinkingLevel: "minimal" },
  // A receipt is about 60-70 output tokens per item. This stops a runaway response early. Up to three
  // photos and a voice note take longer to read
  receipt: { model: FAST_MODEL, maxOutputTokens: 8192, timeoutMs: 60_000, thinkingLevel: "minimal" },
  analysisRequest: { model: FAST_MODEL, maxOutputTokens: 1024, timeoutMs: 30_000, thinkingLevel: "minimal" },
  // Spotting what matters in the numbers is the point, so the report thinks a little (included in the cap)
  analysisReport: { model: REASONING_MODEL, maxOutputTokens: 16_384, timeoutMs: 120_000, thinkingLevel: "low" },
};

export interface OpenList {
  name: string;
  toBuy: string[];
}

/** The person's own names, so the model reuses them. */
export interface NamesContext {
  categories: string[];
  stores: string[];
  knownItems: string[];
  openLists: OpenList[];
  currencySymbol: string;
  /** How much of the person's other currency is 1 [currencySymbol]. */
  conversionRate: number | null;
  /** "Sunday, 2026-10-18", the phone's own day. */
  today: string;
  /** "2026-07-01", the oldest list's day, or null when there is none. */
  firstRecord: string | null;
}

export interface ReportInput {
  said: string;
  periodLabel: string;
  focus: string[];
  question: string | null;
  currencyExample: string;
  language: string;
  data: string;
}

const MAX_KNOWN_ITEMS = 200;
const MAX_LIST_ITEMS = 150;

const list = (values: string[]) => (values.length ? values.join(", ") : "(none yet)");

const ending = (label: string, text: string | null) =>
  text && text.trim() ? `\n\n${label}:\n"""\n${text.trim()}\n"""\nReturn JSON only.` : "\n\nReturn JSON only.";

/**
 * A follow-up: the result the person has in front of them (with their own edits) and what they want
 * changed. The whole result comes back, so nothing they didn't mention moves.
 */
const followUp = (previous: string, text: string | null) =>
  "\n\nFOLLOW-UP\n" +
  "You already produced the result below from the person's input, and they may have edited it since. They now ask for changes. " +
  "Return the whole result again in the same format with their changes made. Change only what they ask for (for example translate or rename items, fix a price or quantity, remove or add an item, change the store, date, category or list) and keep everything else exactly as it is, in the same order. " +
  "When they ask to rename or translate items, a known item name that is clearly the same product wins, copied exactly. " +
  "Prices in the result are already in the person's currency unless an item says otherwise.\n" +
  `Result so far:\n${previous}` +
  (text && text.trim() ? `\n\nChanges asked:\n"""\n${text.trim()}\n"""` : "") +
  "\nReturn JSON only.";

const transcriptRule = (hasAudio: boolean, what: string) =>
  hasAudio
    ? `The ${what} is the attached voice note. Set transcript to what was said, in the language and script it was spoken in.`
    : `The ${what} is typed text. Set transcript to null.`;

function otherCurrencyRule(c: NamesContext): string {
  const symbol = c.currencySymbol;
  const rate = c.conversionRate;
  const example = rate
    ? `The person also pays in a local currency worth much less: 1 ${symbol} is about ${Math.round(rate).toLocaleString("en-US")} of it. `
    : "";
  const converted = rate ? ` (about ${symbol}${(80_000 / rate).toFixed(2)} each)` : "";
  return (
    `- Other currencies: ${example}A price is in another currency when the person names that currency, or when it would make no sense in ${symbol} for that item but makes sense in the local currency: two breads for 80000 each are 80000 LBP each${converted}, not ${symbol}80000. ` +
    `Copy such prices exactly as said and set currency; the app converts them. Amounts that are sensible in ${symbol} stay in ${symbol} with currency null.`
  );
}

export function quickAddPrompt(text: string | null, c: NamesContext, hasAudio: boolean, previous: string | null = null): string {
  return [
    "You turn a person's description of money they spent, or of things they want to buy, into records for a shopping and budgeting app.",
    `Today is ${c.today}. Amounts are in ${c.currencySymbol}.`,
    previous ? transcriptRule(hasAudio, "list of changes") : transcriptRule(hasAudio, "description"),
    "It may be in any language or dialect, including Lebanese Arabic, Arabizi, or a mix of Arabic, English and French. Expect missing punctuation and spoken numbers.",
    "",
    "Group everything into purchases: one per shop visit or occasion. Things bought together at the same place are one purchase; unrelated spending (for example gas and groceries) are separate purchases. Things already bought and things still to buy are always separate purchases, even at the same shop: \"yesterday I bought cheese, and now I'm going to buy eggs\" is two purchases. Include every item mentioned; never drop any.",
    "",
    "For each purchase:",
    "- bought: true for money already spent; false for things the person still wants or needs to buy, or asks to add to a list (\"I want to buy\", \"I'm going to buy\", \"add milk to my weekly list\", \"need eggs\").",
    "- existingList: when the person asks to add items to one of the open lists below, its name copied exactly; otherwise null. Never put already-spent money into an open list unless asked.",
    "- listName: a short title of 2 to 4 words, such as \"Gas fill-up\", \"Groceries at Spinneys\" or \"Dinner out\", in the language of the description. Only name a store that was mentioned.",
    "- category: the existing category below that fits best. If none fits, a new category name of 1 or 2 words. Use \"Groceries\" for food and household supplies.",
    "- store: the shop or place if mentioned, otherwise null. If it is one of the existing stores, use that exact name.",
    "- date: YYYY-MM-DD when a day is mentioned or implied (\"yesterday\", \"on Monday\"), otherwise null.",
    "- items: what was bought, or is to be bought.",
    "",
    "For each item:",
    "- name: short, singular and capitalized, such as \"Gas\", \"Milk\" or \"Haircut\". Keep the product the person named, with any brand or variety they said; never swap it for a more generic or different product (\"halloumi\" stays \"Halloumi\", not \"White cheese\"). Reuse a known item name below only when it is clearly the same product, copied exactly, even when the person said it in another language (\"حليب\" is the known \"Milk\"); \"milk\" is not \"Milk powder\". Otherwise make a new name.",
    "- Packaged products: when a package or bottle size is given, put the size in the name in the style of the known items (\"Halloumi 400g\", \"Pril 1.25l\"), and count packages: quantity is the number of packages (1 unless stated), unit is null and unitPrice is the price of one package. Never price a package per gram or per millilitre.",
    "- quantity: the number of pieces or packages bought (2 for \"two breads\"), or the amount for goods bought loose by weight or volume (40 for \"40 liters of gas\", 2 for \"2 kilos of tomatoes\"); otherwise 1.",
    "- unit: a short unit (l, kg, g, ml) only for goods bought loose by weight or volume, otherwise null.",
    "- unitPrice: the price of one piece, package, or unit if stated, expected or clearly implied, otherwise null.",
    "- totalPrice: the total paid for this item if stated, otherwise null.",
    "- If one amount covers several things, record a single item named for the whole purchase rather than guessing a split.",
    `- currency: null when the price is in ${c.currencySymbol}. When it is in another currency, its ISO 4217 code (LBP for Lebanese pounds: "lira", "L.L.", "ليرة").`,
    "- Never invent prices. Prices are plain numbers without currency symbols or thousands separators.",
    otherCurrencyRule(c),
    "",
    `Existing categories: ${list(c.categories)}`,
    `Existing stores: ${list(c.stores)}`,
    `Open lists: ${list(c.openLists.map((l) => l.name))}`,
    `Known items: ${list(c.knownItems.slice(0, MAX_KNOWN_ITEMS))}`,
  ].join("\n") + (previous ? followUp(previous, text) : ending("Description", text));
}

export interface ReceiptInput {
  /** How many photos of the receipt are attached, top to bottom. */
  photos: number;
  /** The person's note: typed text (a voice note is attached when [hasAudio]). */
  note: string | null;
  hasAudio: boolean;
  /** For a follow-up: the result so far, as JSON. */
  previous: string | null;
}

export function receiptPrompt(c: NamesContext, r: ReceiptInput = { photos: 1, note: null, hasAudio: false, previous: null }): string {
  const openLists = c.openLists.length
    ? c.openLists.map((l) => `- ${l.name}: ${list(l.toBuy.slice(0, MAX_LIST_ITEMS))}`).join("\n")
    : "(none)";
  const hasNote = r.hasAudio || !!r.note?.trim();
  const photos = r.photos > 1
    ? `These are ${r.photos} photos of one long shop receipt, normally in order from its top to its bottom; if they aren't, put them in order by what they show (the store name is at the top, the total at the bottom). They usually overlap: a line that shows in two photos is one line, so never count it twice. Read them together as one receipt.`
    : "This is a photo of a shop receipt.";
  const note = r.previous
    ? [transcriptRule(r.hasAudio, "list of changes")]
    : hasNote
      ? [
          r.hasAudio
            ? "The person also attached a voice note about this receipt. Set transcript to what was said, in the language and script it was spoken in."
            : "The person also typed a note about this receipt (below). Set transcript to null.",
          "Follow the note: it may explain what is hard to read, how to name or translate products, which lines to leave out, the store or the date. When the note and the rules below disagree, the note wins.",
        ]
      : ["Set transcript to null."];
  return [
    `${photos} It may be in Arabic, English, or both, and may be laid out right-to-left.`,
    `The person's currency is ${c.currencySymbol}.`,
    ...note,
    "",
    "Read:",
    "- store: the shop name as the person would say it. If it is one of the existing stores, use that exact name. null if not printed.",
    "- date: the purchase date as YYYY-MM-DD, or null if not printed. Read day/month/year dates day first.",
    "- currency: the ISO 4217 code of the item line prices (LBP for L.L. or ل.ل., USD for $), or null if unclear. Receipts may also show totals or payments in a second currency; ignore those and judge by the item prices.",
    "- listName: a short title of 2 to 4 words such as \"Groceries at Spinneys\".",
    "- category: the existing category that fits best, or a new name of 1 or 2 words. Use \"Groceries\" for food and household supplies.",
    "- existingList: if most items are things to buy on one of the open lists below, that list's name copied exactly; otherwise null.",
    "- items: ONLY the purchased line items.",
    "",
    "Item rules:",
    "- Ignore address, phone, cashier, totals, subtotals, VAT/tax lines, cash, change, rounding, loyalty points and payment info.",
    "- name: when the line is clearly the same product as one of the known items below, even if printed in another language, script or abbreviated (\"حليب المراعي 1ل\" can be the known \"Almarai Milk 1l\"), copy that known item name exactly. Otherwise keep the product name as printed, in its original script, unless the person asks for it translated or renamed.",
    "- listItem: the open-list item (from any list below) this line is, copied exactly, when it is clearly the same product even if named in another language; otherwise null.",
    "- Convert any Arabic-Indic digits to Western digits (0-9).",
    "- All prices must be plain numbers: no currency symbols and no thousands separators (e.g. 150000 or 2.5).",
    "- Packaged products: a size in the product name (\"Labneh 500g\", \"Milk 1l\", \"Eggs 30\") is the size of one package, not the quantity. quantity is the number of packages (2 for \"2 x 95,000\", 1 unless the receipt shows more), unit is null, and unitPrice is the price of one package. Never price a package per gram, millilitre or piece.",
    "- Bundles and offers: when a line is several of the same product sold together (\"3x\", \"x6\", \"pack of 4\", \"3+1\", \"2 for 1\", \"bundle\", \"offer\", \"عرض\", \"حزمة\") and the number of pieces can be read, name the single product without the offer words, set quantity to the number of pieces (4 for \"3+1\") and keep totalPrice as printed, so the price per piece comes out right. When it only says offer and the count can't be read, keep quantity 1.",
    "- quantity is how many packages or units, or how much weight of loose goods, was bought; use 1 if the receipt does not show it.",
    "- unit is the unit (kg, g, l, ml) only for loose goods sold by weight or volume (\"Tomatoes 1.5 kg\" is 1.5 kg), otherwise null.",
    "- totalPrice is the line total printed for that item (after quantity).",
    "- unitPrice is the price of one unit if printed, otherwise null.",
    "- Use at most 2 decimal places for every price. Never output long strings of digits.",
    "- If a value is not readable, use null instead of guessing.",
    "",
    `Existing categories: ${list(c.categories)}`,
    `Existing stores: ${list(c.stores)}`,
    `Known items: ${list(c.knownItems.slice(0, MAX_KNOWN_ITEMS))}`,
    "Open lists with their items to buy:",
    openLists,
  ].join("\n") + (r.previous ? followUp(r.previous, r.note) : r.note?.trim() ? ending("Note", r.note) : "\n\nReturn JSON only.");
}

export function analysisRequestPrompt(text: string | null, c: NamesContext, hasAudio: boolean): string {
  const first = c.firstRecord ?? "today";
  return [
    "You read a person's request to analyze their data in a shopping and budgeting app. Don't analyze anything; only describe the request.",
    `Today is ${c.today}. Their records start on ${first}.`,
    transcriptRule(hasAudio, "request"),
    "It may be in any language or dialect, including Lebanese Arabic, Arabizi, or a mix of Arabic, English and French.",
    "",
    "Return:",
    `- startDate, endDate: the period asked for, as YYYY-MM-DD. "this month" is the 1st of this month to today; "last month" is the whole previous calendar month; "since X" or "from X" is X to today; "last 3 months" is the 1st of the month two months ago to today; a named month is that whole month, in the most recent year it has already started; "this year" is January 1 to today; "all time" or "everything" is ${first} to today. Both null when no period is mentioned.`,
    "- focus: what they want to look at. \"spending\": where the money goes, totals, categories, stores. \"prices\": how prices of things changed, where things are cheaper. \"habits\": how often and when they shop, patterns. All three when they ask generally (\"analyze my spending\", \"how am I doing\").",
    "- category, store, item: only when they ask about one in particular; copy the existing name exactly when it is one of those below, otherwise null.",
    "- question: anything else they want to know or have explained, short, in their own words and language. null when the request is only a period and a focus.",
    "",
    `Existing categories: ${list(c.categories)}`,
    `Existing stores: ${list(c.stores)}`,
    `Known items: ${list(c.knownItems.slice(0, MAX_KNOWN_ITEMS))}`,
  ].join("\n") + ending("Request", text);
}

export function analysisReportPrompt(r: ReportInput): string {
  return [
    `You are a sharp, friendly personal finance analyst inside a shopping and budgeting app. Analyze the person's data below and write a short report for a phone screen, in ${r.language}.`,
    // The app shows Arabic with Western digits, as receipts and price entry do
    ...(/arabic/i.test(r.language) ? ["Write Modern Standard Arabic, simple and friendly, with Western digits (0-9) for every number, amount and date; keep store and item names as they appear in the data, but call the built-in category Groceries «البقالة». Name months the Levantine way (كانون الثاني، شباط، آذار، نيسان، أيار، حزيران، تموز، آب، أيلول، تشرين الأول، تشرين الثاني، كانون الأول), never يناير، فبراير and the like."] : []),
    "",
    `They asked: "${r.said.trim() || `Analyze ${r.periodLabel}`}"`,
    `Look at: ${r.focus.join(", ")}.`,
    r.question ? `Make sure the report answers: ${r.question}` : "",
    "",
    "Rules:",
    "- Use only the data below. Never invent purchases, prices or figures. Quote amounts as they appear; when you work something out (a difference, a share, a per-day figure) make it exact.",
    `- Write amounts with the currency symbol as in the data, such as ${r.currencyExample}, never spelled out in words.`,
    "- Be specific: name the items, stores and categories behind each point, with their amounts. Prefer what is surprising, changing or actionable over restating totals.",
    "- Price trends: compare an item's unit prices over time and between stores, only for items with history below. Say how sure a trend is when it rests on two or three purchases.",
    "- Habits: how often they shop, typical size of a purchase, regular items, anything that stands out.",
    "- If there is little data, say so plainly and keep the report short. Never pad.",
    "- Plain text only: no markdown, no asterisks, no emojis.",
    "",
    "Write:",
    "- title: 2 to 5 words naming the period or topic, such as \"September spending\" or \"Grocery prices since June\".",
    "- summary: 2 or 3 sentences with the main takeaways.",
    "- sections: 2 to 5, each with a kind (spending, prices, habits, stores, other), a heading of at most 6 words, a body of 1 to 3 sentences, and 0 to 4 points of one short line each.",
    "- tips: 0 to 3 concrete suggestions that follow from the data, such as where an item is cheaper. None when nothing useful follows.",
  ].join("\n") + "\n\nDATA\n" + r.data;
}

/**
 * The person's own instructions, added after the prompt. They can change how things are named or
 * read, but not the answer's format: the schema still holds it to the same JSON.
 */
export function instructionsPart(instructions: string): string {
  return [
    "THE PERSON'S OWN INSTRUCTIONS",
    "The person added these in the app's settings. Follow them where they apply, as long as they don't change the JSON format or make you invent prices.",
    `"""\n${instructions.trim()}\n"""`,
  ].join("\n");
}

/**
 * The prompts as the person can see them in Settings, with placeholders where their own names,
 * words or figures go.
 */
export function basePrompts(): Record<"quickAdd" | "receipt" | "analysisReport", string> {
  const c: NamesContext = {
    categories: ["[your categories]"],
    stores: ["[your stores]"],
    knownItems: ["[your item library, most bought first]"],
    openLists: [{ name: "[each open list]", toBuy: ["[its items to buy]"] }],
    currencySymbol: "$",
    conversionRate: null,
    today: "[today]",
    firstRecord: null,
  };
  return {
    quickAdd: quickAddPrompt("[what you typed, or your voice note]", c, false),
    receipt: receiptPrompt(c, { photos: 1, note: "[your note, if you add one]", hasAudio: false, previous: null }),
    analysisReport: analysisReportPrompt({
      said: "[what you asked]",
      periodLabel: "[the period]",
      focus: ["spending", "price trends", "shopping habits"],
      question: null,
      currencyExample: "$4.50",
      language: "English",
      data: "[your figures for the period: totals, purchases, items, stores and prices]",
    }),
  };
}

// ---------- response schemas (Gemini's OpenAPI subset) ----------

const STRING = { type: "STRING" };
const NULLABLE_STRING = { type: "STRING", nullable: true };
const NULLABLE_NUMBER = { type: "NUMBER", nullable: true };

export const SECTION_KINDS = ["spending", "prices", "habits", "stores", "other"];

export const SCHEMAS: Record<Feature, object> = {
  quickAdd: {
    type: "OBJECT",
    properties: {
      transcript: NULLABLE_STRING,
      purchases: {
        type: "ARRAY",
        items: {
          type: "OBJECT",
          properties: {
            bought: { type: "BOOLEAN" },
            listName: STRING,
            existingList: NULLABLE_STRING,
            category: NULLABLE_STRING,
            store: NULLABLE_STRING,
            date: NULLABLE_STRING,
            items: {
              type: "ARRAY",
              items: {
                type: "OBJECT",
                properties: {
                  name: STRING,
                  quantity: { type: "NUMBER" },
                  unit: NULLABLE_STRING,
                  unitPrice: NULLABLE_NUMBER,
                  totalPrice: NULLABLE_NUMBER,
                  currency: NULLABLE_STRING,
                },
                propertyOrdering: ["name", "quantity", "unit", "unitPrice", "totalPrice", "currency"],
                required: ["name", "quantity"],
              },
            },
          },
          propertyOrdering: ["bought", "listName", "existingList", "category", "store", "date", "items"],
          required: ["bought", "listName", "items"],
        },
      },
    },
    propertyOrdering: ["transcript", "purchases"],
    required: ["purchases"],
  },
  receipt: {
    type: "OBJECT",
    properties: {
      transcript: NULLABLE_STRING,
      store: NULLABLE_STRING,
      date: NULLABLE_STRING,
      currency: NULLABLE_STRING,
      listName: STRING,
      category: NULLABLE_STRING,
      existingList: NULLABLE_STRING,
      items: {
        type: "ARRAY",
        items: {
          type: "OBJECT",
          properties: {
            name: STRING,
            listItem: NULLABLE_STRING,
            quantity: { type: "NUMBER" },
            unit: NULLABLE_STRING,
            unitPrice: NULLABLE_NUMBER,
            totalPrice: NULLABLE_NUMBER,
          },
          propertyOrdering: ["name", "listItem", "quantity", "unit", "unitPrice", "totalPrice"],
          required: ["name", "quantity", "totalPrice"],
        },
      },
    },
    propertyOrdering: ["transcript", "store", "date", "currency", "listName", "category", "existingList", "items"],
    required: ["listName", "items"],
  },
  analysisRequest: {
    type: "OBJECT",
    properties: {
      transcript: NULLABLE_STRING,
      startDate: NULLABLE_STRING,
      endDate: NULLABLE_STRING,
      focus: { type: "ARRAY", items: { type: "STRING", enum: ["spending", "prices", "habits"] } },
      category: NULLABLE_STRING,
      store: NULLABLE_STRING,
      item: NULLABLE_STRING,
      question: NULLABLE_STRING,
    },
    propertyOrdering: ["transcript", "startDate", "endDate", "focus", "category", "store", "item", "question"],
    required: ["focus"],
  },
  analysisReport: {
    type: "OBJECT",
    properties: {
      title: STRING,
      summary: STRING,
      sections: {
        type: "ARRAY",
        items: {
          type: "OBJECT",
          properties: {
            kind: { type: "STRING", enum: SECTION_KINDS },
            heading: STRING,
            body: STRING,
            points: { type: "ARRAY", items: STRING },
          },
          propertyOrdering: ["kind", "heading", "body", "points"],
          required: ["kind", "heading", "body"],
        },
      },
      tips: { type: "ARRAY", items: STRING },
    },
    propertyOrdering: ["title", "summary", "sections", "tips"],
    required: ["title", "summary", "sections"],
  },
};
