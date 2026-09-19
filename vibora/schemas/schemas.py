from .messages import EnglishLanguage
from ..request import Request


class Schema:

    _fields = []

    def __init__(self, silent: bool=False):
        """

        :param silent:
        """
        pass

    @classmethod
    async def load(cls, values: dict, language: dict=EnglishLanguage, context: dict=None,
                   sources: dict=None) -> 'Schema':
        """

        :param sources: maps a field source identifier ('body', 'query',
        'path') to the values dict it must be extracted from. When omitted
        every field is read straight from ``values`` (legacy behaviour).
        :param context:
        :param values:
        :param language:
        :return:
        """
        pass

    @classmethod
    async def load_form(cls, request: Request, language: dict=EnglishLanguage, context: dict=None) -> 'Schema':
        """

        :param context:
        :param request:
        :param language:
        :return:
        """
        pass

    @classmethod
    async def load_json(cls, request: Request, language: dict = EnglishLanguage, context: dict=None) -> 'Schema':
        """

        :param context:
        :param request:
        :param language:
        :return:
        """
        pass

    @classmethod
    async def load_query(cls, request: Request, language: dict=EnglishLanguage,
                         context: dict=None, path_values: dict=None) -> 'Schema':
        """Loads query-sourced fields (and optional path-sourced fields)
        from the request URL query string."""
        pass

    @classmethod
    async def load_path(cls, request: Request, language: dict=EnglishLanguage,
                        context: dict=None, path_values: dict=None,
                        include_query: bool=False) -> 'Schema':
        """Loads path-sourced fields from the route parameters forwarded
        through ``path_values``."""
        pass

    @classmethod
    async def load_request(cls, request: Request, language: dict=EnglishLanguage,
                           context: dict=None, path_values: dict=None) -> 'Schema':
        """Routes each field to its declared input source (body, query or
        path) automatically."""
        pass
