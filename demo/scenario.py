class Config:
    def __init__(self):
        self.retries = 3
        self.timeout = 30


def connect(cfg):
    for attempt in range(cfg.retries):
        dial(cfg.timeout)


def report(cfg):
    print(f"retries={cfg.retries}")
