import { z } from "zod";

export const DEVICE_ID_PATTERN = /^[a-z0-9][a-z0-9-]{0,62}$/;
export const CARD_ID_PATTERN = /^[A-Za-z0-9_-]{8,80}$/;
export const MAX_TTL_SECONDS = 86_400;

export const cardKindSchema = z.enum(["message", "progress", "image"]);
export const cardPrioritySchema = z.enum(["ambient", "normal", "urgent"]);

export const cardInputSchema = z.object({
  kind: cardKindSchema.default("message"),
  title: z.string().trim().min(1).max(160),
  body: z.string().max(12_000).refine((value) => !/<\/?[A-Za-z!][^>]*>/.test(value) && !/!\[[^\]]*\]\s*\(/.test(value), "HTML and Markdown images are not allowed").default(""),
  progress: z.number().min(0).max(100).optional(),
  asset_id: z.string().regex(CARD_ID_PATTERN).optional(),
  priority: cardPrioritySchema.default("normal"),
  ttl_seconds: z.number().int().min(1).max(MAX_TTL_SECONDS).default(300),
  pinned: z.boolean().default(false),
  replace_key: z.string().trim().min(1).max(120).optional(),
}).superRefine((card, context) => {
  if (card.kind === "progress" && card.progress === undefined) {
    context.addIssue({ code: "custom", path: ["progress"], message: "progress cards require progress" });
  }
  if (card.kind === "image" && card.asset_id === undefined) {
    context.addIssue({ code: "custom", path: ["asset_id"], message: "image cards require asset_id" });
  }
});

export const cardPatchSchema = z.object({
  title: z.string().trim().min(1).max(160).optional(),
  body: z.string().max(12_000).refine((value) => !/<\/?[A-Za-z!][^>]*>/.test(value) && !/!\[[^\]]*\]\s*\(/.test(value), "HTML and Markdown images are not allowed").optional(),
  progress: z.number().min(0).max(100).optional(),
  priority: cardPrioritySchema.optional(),
  ttl_seconds: z.number().int().min(1).max(MAX_TTL_SECONDS).optional(),
  pinned: z.boolean().optional(),
}).refine((value) => Object.keys(value).length > 0, "at least one field is required");

export const providerSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("none") }),
  z.object({
    kind: z.literal("trmnl-hosted"),
    base_url: z.string().url().startsWith("https://"),
    device_id: z.string().min(1).max(200),
    access_token: z.string().min(8).max(1000),
  }),
  z.object({
    kind: z.literal("terminus"),
    base_url: z.string().url(),
    device_id: z.string().min(1).max(200),
    access_token: z.string().min(8).max(1000).optional(),
    allow_private_http: z.boolean().default(false),
  }),
]);

export const devicePollQuerySchema = z.object({
  cursor: z.coerce.number().int().min(0).default(0),
  wait: z.coerce.number().int().min(0).max(25).default(25),
});

export const clientScopeSchema = z.enum([
  "dashboard:read", "dashboard:write", "dashboard:clear", "screen:read", "screen:write",
  "status:read", "device:apps", "device:control", "chat:bridge:read", "chat:bridge:write",
]);

export const CHAT_MESSAGE_MAX_BYTES = 16 * 1024;
export const chatActionSchema = z.discriminatedUnion("kind", [
  z.object({ id: z.string().uuid(), kind: z.literal("create"), session_key: z.string().min(8).max(240), agent_id: z.string().min(1).max(160), title: z.string().trim().min(1).max(160) }),
  z.object({ id: z.string().uuid(), kind: z.enum(["send", "retry"]), session_key: z.string().min(8).max(240), message_id: z.string().uuid(), text: z.string().min(1).max(CHAT_MESSAGE_MAX_BYTES) }),
  z.object({ id: z.string().uuid(), kind: z.literal("regenerate"), session_key: z.string().min(8).max(240), text: z.string().min(1).max(CHAT_MESSAGE_MAX_BYTES) }),
  z.object({ id: z.string().uuid(), kind: z.literal("abort"), session_key: z.string().min(8).max(240) }),
  z.object({ id: z.string().uuid(), kind: z.literal("rename"), session_key: z.string().min(8).max(240), title: z.string().trim().min(1).max(160) }),
  z.object({ id: z.string().uuid(), kind: z.enum(["archive", "pin", "hide", "restore", "mark_read"]), session_key: z.string().min(8).max(240), value: z.boolean().default(true) }),
]);

export const chatActionClaimSchema = z.object({
  worker_id: z.string().trim().min(3).max(160),
  lease_seconds: z.coerce.number().int().min(15).max(120).default(45),
});

export const chatActionLeaseSchema = z.object({
  worker_id: z.string().trim().min(3).max(160),
  lease_seconds: z.coerce.number().int().min(15).max(120).default(45),
});

export const chatBridgeSyncSchema = z.object({
  agents: z.array(z.object({ id: z.string().min(1).max(160), name: z.string().trim().min(1).max(160) })).max(100).default([]),
  sessions: z.array(z.object({
    session_key: z.string().min(8).max(240), agent_id: z.string().min(1).max(160),
    channel: z.string().min(1).max(80), title: z.string().trim().min(1).max(160),
    updated_at: z.string().datetime(), archived: z.boolean().default(false),
    run_status: z.enum(["idle", "working", "failed"]).default("idle"), run_id: z.string().max(240).nullable().default(null),
  })).max(100).default([]),
  messages: z.array(z.object({
    id: z.string().min(1).max(240), session_key: z.string().min(8).max(240),
    role: z.enum(["user", "assistant", "system"]), status: z.enum(["queued", "streaming", "complete", "failed"]),
    body: z.string().max(128 * 1024), asset_id: z.string().regex(CARD_ID_PATTERN).nullable().default(null),
    run_id: z.string().max(240).nullable().default(null), created_at: z.string().datetime(),
  })).max(1000).default([]),
  receipts: z.array(z.object({ id: z.string().uuid(), status: z.enum(["completed", "failed"]), detail: z.string().max(300).default("") })).max(100).default([]),
  error: z.string().max(300).nullable().default(null),
});

export const tabletAppIdSchema = z.string().regex(/^(?:external::)?[a-zA-Z0-9][a-zA-Z0-9._-]{0,126}$/);
export const tabletLaunchSchema = z.object({ app_id: tabletAppIdSchema });

export const paperboardCommandActionSchema = z.enum([
  "previous", "next", "select_ambient", "leave_ambient", "show_controls",
  "hide_controls", "refresh", "exit", "show_dashboard", "show_screen",
]);

export const paperboardCommandSchema = z.object({
  action: paperboardCommandActionSchema,
});

export const commandResultSchema = z.object({
  id: z.string().regex(CARD_ID_PATTERN),
  status: z.enum(["completed", "failed"]),
  detail: z.string().max(300).default(""),
});

export const paperboardUiStateSchema = z.object({
  application: z.literal("paperboard"),
  protocol_version: z.literal(2).default(2),
  mode: z.enum(["dashboard", "screen", "reader"]).default("dashboard"),
  foreground: z.boolean(),
  rendered_cursor: z.number().int().min(0),
  visible_card_id: z.string().regex(CARD_ID_PATTERN).nullable().default(null),
  visible_index: z.number().int().min(0).nullable().default(null),
  card_count: z.number().int().min(0).default(0),
  ambient_mode: z.boolean().default(false),
  controls_visible: z.boolean().default(false),
  history_index: z.number().int().min(0).nullable().default(null),
  history_count: z.number().int().min(0).default(0),
  scroll_offset: z.number().min(0).default(0),
  active_session_id: z.string().regex(CARD_ID_PATTERN).nullable().default(null),
  active_message_id: z.string().regex(CARD_ID_PATTERN).nullable().default(null),
  last_interaction_at: z.string().datetime().nullable().default(null),
  last_action: z.string().max(80).default(""),
  last_result: z.string().max(300).default(""),
});

const optionSchema = z.object({ id: z.string().regex(CARD_ID_PATTERN), label: z.string().min(1).max(100) });
const actionBase = { id: z.string().regex(CARD_ID_PATTERN), label: z.string().min(1).max(100) };

export const screenActionSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("choice"), id: z.string().regex(CARD_ID_PATTERN), label: z.string().min(1).max(100) }),
  z.object({ type: z.literal("confirm"), id: z.string().regex(CARD_ID_PATTERN), label: z.string().min(1).max(100), confirm_label: z.string().min(1).max(60).default("Confirm"), cancel_label: z.string().min(1).max(60).default("Cancel") }),
  z.object({ type: z.literal("checklist"), ...actionBase, options: z.array(optionSchema).min(1).max(24) }),
  z.object({ type: z.literal("single_select"), ...actionBase, options: z.array(optionSchema).min(1).max(24), value: z.string().regex(CARD_ID_PATTERN).optional() }),
  z.object({ type: z.literal("multi_select"), ...actionBase, options: z.array(optionSchema).min(1).max(24), values: z.array(z.string().regex(CARD_ID_PATTERN)).max(24).default([]) }),
  z.object({ type: z.literal("toggle"), ...actionBase, value: z.boolean().default(false) }),
  z.object({ type: z.literal("slider"), ...actionBase, minimum: z.number(), maximum: z.number(), step: z.number().positive(), value: z.number() }).refine((item) => item.maximum > item.minimum && item.value >= item.minimum && item.value <= item.maximum, "invalid slider range or value"),
  z.object({ type: z.literal("handwriting"), ...actionBase, height: z.number().int().min(160).max(900).default(360) }),
  z.object({ type: z.literal("link"), ...actionBase, url: z.string().url().startsWith("https://") }),
]);

export const screenMessageInputSchema = z.object({
  title: z.string().trim().min(1).max(160),
  body: z.string().max(12_000).default(""),
  asset_id: z.string().regex(CARD_ID_PATTERN).optional(),
  actions: z.array(screenActionSchema).max(32).default([]),
  replace_key: z.string().trim().min(1).max(120).optional(),
  foreground: z.boolean().default(true),
});

export const screenSessionInputSchema = z.object({
  title: z.string().trim().min(1).max(160),
});

export const penStrokePointSchema = z.object({
  x: z.number().min(0).max(1), y: z.number().min(0).max(1),
  pressure: z.number().min(0).max(1).default(0.5), t_ms: z.number().int().min(0),
});
export const penStrokeSchema = z.object({
  id: z.string().regex(CARD_ID_PATTERN), tool: z.enum(["pen", "eraser"]).default("pen"),
  points: z.array(penStrokePointSchema).min(1).max(20_000),
});

export const screenEventValueSchema = z.union([
  z.string().max(2_000), z.number(), z.boolean(), z.array(z.string().regex(CARD_ID_PATTERN)).max(24),
  z.object({ decision: z.enum(["confirm", "cancel"]) }),
  z.object({ strokes: z.array(penStrokeSchema).max(256), preview_asset_id: z.string().regex(CARD_ID_PATTERN).optional() }),
]);

export const screenEventInputSchema = z.object({
  message_id: z.string().regex(CARD_ID_PATTERN),
  action_id: z.string().regex(CARD_ID_PATTERN),
  value: screenEventValueSchema,
});

/* Temporary source-level aliases while the relay migration is implemented. */
export const canvasActionSchema = screenActionSchema;
export const canvasMessageInputSchema = screenMessageInputSchema;
export const canvasSessionInputSchema = screenSessionInputSchema;
export const canvasEventInputSchema = screenEventInputSchema;

export type CardInput = z.infer<typeof cardInputSchema>;
export type CardPatch = z.infer<typeof cardPatchSchema>;
export type ProviderInput = z.infer<typeof providerSchema>;
export type ClientScope = z.infer<typeof clientScopeSchema>;
export type ChatAction = z.infer<typeof chatActionSchema>;
export type ChatBridgeSync = z.infer<typeof chatBridgeSyncSchema>;
export type PaperboardCommandAction = z.infer<typeof paperboardCommandActionSchema>;
export type PaperboardUiState = z.infer<typeof paperboardUiStateSchema>;
export type CanvasMessageInput = z.infer<typeof canvasMessageInputSchema>;
export type CanvasSessionInput = z.infer<typeof canvasSessionInputSchema>;
export type CanvasEventInput = z.infer<typeof canvasEventInputSchema>;
export type TabletLaunchInput = z.infer<typeof tabletLaunchSchema>;
export type ScreenMessageInput = z.infer<typeof screenMessageInputSchema>;
export type ScreenSessionInput = z.infer<typeof screenSessionInputSchema>;
export type ScreenEventInput = z.infer<typeof screenEventInputSchema>;

export interface DeliveryCard {
  id: string;
  cursor: number;
  kind: "message" | "progress" | "image";
  title: string;
  body: string;
  progress?: number;
  asset_url?: string;
  priority: "ambient" | "normal" | "urgent";
  pinned: boolean;
  created_at: string;
  expires_at?: string;
}
