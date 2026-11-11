import logging

from comfy.ldm.modules.attention import attention_pytorch

from .backend.config import VERSION

logger = logging.getLogger("lazycomfy")


class LazyComfyInfo:
    @classmethod
    def INPUT_TYPES(cls):
        return {}
    RETURN_TYPES = ()
    OUTPUT_NODE = True
    FUNCTION = "version"
    CATEGORY = "lazycomfy"

    def version(self):
        return {"ui": {"text": (f"LazyComfy {VERSION}",)}}


class LazySeedVR2Attention:
    """Force PyTorch SDPA on a SeedVR2 model.

    SeedVR2's window attention never forwards transformer_options, so the core
    ModelAttentionBackend patch cannot reach it. Overriding the model's own
    comfy_attention function is the only per-workflow way to keep flash
    attention from producing black (NaN) 7B output.
    """

    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"model": ("MODEL",)}}

    RETURN_TYPES = ("MODEL",)
    FUNCTION = "patch"
    CATEGORY = "lazycomfy"

    def patch(self, model):
        m = model.clone()
        m.model.diffusion_model.comfy_attention.function = attention_pytorch
        return (m,)


NODE_CLASS_MAPPINGS = {
    "LazyComfyInfo": LazyComfyInfo,
    "LazySeedVR2Attention": LazySeedVR2Attention,
}
NODE_DISPLAY_NAME_MAPPINGS = {
    "LazyComfyInfo": "LazyComfy Info",
    "LazySeedVR2Attention": "Lazy SeedVR2 Attention",
}

try:
    from .backend.routes import register

    register()
except Exception as e:
    logger.warning("LazyComfy: failed to register routes: %s", e)
