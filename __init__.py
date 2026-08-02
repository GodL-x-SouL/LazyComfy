import logging

from .backend.config import VERSION

logger = logging.getLogger("lazycomfy")


class LazyComfyInfo:
    INPUT_TYPES = {}
    RETURN_TYPES = ()
    OUTPUT_NODE = True
    FUNCTION = "version"
    CATEGORY = "lazycomfy"

    def version(self):
        return {"ui": {"text": (f"LazyComfy {VERSION}",)}}


NODE_CLASS_MAPPINGS = {"LazyComfyInfo": LazyComfyInfo}
NODE_DISPLAY_NAME_MAPPINGS = {"LazyComfyInfo": "LazyComfy Info"}
WEB_DIRECTORY = "./web/js"

try:
    from .backend.routes import register

    register()
except Exception as e:
    logger.warning("LazyComfy: failed to register routes: %s", e)
