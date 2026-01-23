def module(name):
    def decorator(fn):
        fn._test_module = name
        return fn
    return decorator
