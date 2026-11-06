import { serve } from "../../../src/dl.js";

/** @type {PagesFunction<{ DL: R2Bucket }>} */
export const onRequest = (ctx) => serve(ctx.request, ctx.env.DL, ctx.params.path);
