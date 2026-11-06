import { arch } from "../../src/arch.js";

export const onRequest = (ctx) => arch(ctx.request, ctx.env, ctx.params.path);
