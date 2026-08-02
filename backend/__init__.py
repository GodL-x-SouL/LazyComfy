class LazyComfyError(Exception):
    def __init__(self, error_type, message, details=None):
        super().__init__(message)
        self.error_type = error_type
        self.message = message
        self.details = details
