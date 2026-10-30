from . import base, github

PROVIDERS = {"github": github.GitHubProvider}


def make(name, conn, cfg, **kw):
    return PROVIDERS[name](conn, cfg, **kw)


__all__ = ["PROVIDERS", "base", "github", "make"]
