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

export type CardInput = z.infer<typeof cardInputSchema>;
export type CardPatch = z.infer<typeof cardPatchSchema>;
export type ProviderInput = z.infer<typeof providerSchema>;

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
