from asyncio import iscoroutinefunction
from typing import List as TList, Dict
from vibora.request import Request
from collections import defaultdict
from .validator import Validator
from .fields cimport Field, String, Integer, Number, Nested, List, File
from .fields import BODY, QUERY, PATH, DEFAULT_SOURCE
from ..messages import Messages, EnglishLanguage
from ..exceptions import ValidationError, InvalidSchema


optimized_fields = (String, Integer, List, Number, Nested, File)
type_index = {str: String, int: Integer, float: Number, TList: List}


def _flatten_params(params) -> dict:
    """Flattens query-string style params ({'key': ['value']}) into a
    plain dict taking the first value of every key."""
    values = {}
    for key, value in params.items():
        if isinstance(value, (list, tuple)):
            if value:
                values[key] = value[0]
        else:
            values[key] = value
    return values



class SchemaCreator(type):

    @staticmethod
    def prepare_field(field: Field, attribute_name: str):
        """

        :param field:
        :param attribute_name:
        :return:
        """
        if not field.load_from:
            field.load_from = attribute_name
        if not field.load_into:
            field.load_into = attribute_name
        if field.__class__ in optimized_fields:
            field.is_async = False
        validators = []
        for user_function in field.validators:
            if isinstance(user_function, staticmethod):
                user_function = user_function.__func__
            if isinstance(user_function, classmethod):
                raise SyntaxError(f'Class methods are not allowed as validators. ({user_function.__func__})')
            if iscoroutinefunction(user_function):
                field.is_async = True
            if not isinstance(user_function, Validator):
                validators.append(Validator(user_function))
            else:
                validators.append(user_function)
        field.validators = validators
        return field

    def __new__(mcs, *args, **kwargs):
        """

        :param args:
        :param kwargs:
        :return:
        """
        fields = {}

        # Parsing declared fields.
        for attribute_name, value in args[2].items():
            if isinstance(value, Field):
                if attribute_name not in args[2].get('__annotations__', {}):
                    raise SyntaxError(f'Attribute "{attribute_name}" of class "{args[0]}" is missing a type hint. ')
                fields[attribute_name] = SchemaCreator.prepare_field(value, attribute_name)
            elif not attribute_name.startswith('_') and attribute_name in args[2].get('__annotations__', {}):
                chosen_type = args[2].get('__annotations__')[attribute_name]
                if isinstance(chosen_type, Field):
                    new_field = chosen_type
                    new_field.default = value
                    new_field.required = False
                else:
                    new_field = type_index[chosen_type](default=value, required=False)
                fields[attribute_name] = SchemaCreator.prepare_field(new_field, attribute_name)

        # Looking for named vars.
        for name, type_ in args[2].get('__annotations__', {}).items():
            if name not in fields and not name.startswith('_'):
                if isinstance(type_, Field):
                    fields[name] = SchemaCreator.prepare_field(type_, name)
                else:
                    fields[name] = SchemaCreator.prepare_field(type_index[type_](required=True), name)

        args[2]['_fields'] = list(fields.values())
        return type.__new__(mcs, *args)


cdef inline translate_errors(dict errors, dict language):
        """

        :param errors:
        :param language:
        :return:
        """
        cdef dict translated_errors = {}
        cdef str key
        for key, field_errors in errors.items():
            for error in field_errors:
                if key not in translated_errors:
                    translated_errors[key] = []
                if error.error_code in language:
                    translated_errors[key].append({
                        'msg': language[error.error_code].format(**error.extra), 'error_code': error.error_code
                    })
                else:
                    translated_errors[key].append({'msg': error.msg, 'error_code': 0})
        return translated_errors


cdef inline add_error(dict errors, str key, object error):
    if key in errors:
        errors[key].append(error)
    else:
        errors[key] = [error]


class Schema(metaclass=SchemaCreator):

    _fields = []

    def __init__(self, silent: bool=False):
        if not silent:
            raise ValidationError('Schema instances should not be instantiated outside factory methods '
                                  'because of async features. Use the .load(). or silent parameter to skip '
                                  'this validation.')

    @classmethod
    async def load(cls, dict values, dict language=EnglishLanguage, dict context=None,
                   dict sources=None) -> 'Schema':
        """Loads and validates data into the schema.

        Backward compatible signature: when ``sources`` is not provided every
        field is read straight from ``values`` (historical behaviour). When it
        is provided, each field is routed to its declared input source
        (``body`` / ``query`` / ``path``) using ``load_from`` as the lookup
        key inside that source.
        """
        cdef Field field
        cdef dict errors
        cdef dict source_values
        cdef bint routed
        routed = sources is not None
        if context is None:
            context = {}
        instance = cls(silent=True)
        errors = {}
        for field in cls._fields:
            present = False
            raw_value = None
            if routed:
                source_values = sources.get(field.source or DEFAULT_SOURCE)
                if source_values is not None and field.load_from in source_values:
                    present = True
                    raw_value = source_values[field.load_from]
            elif field.load_from in values:
                present = True
                raw_value = values[field.load_from]
            if present:
                try:
                    if field.is_async:
                        value = await field.pipeline(raw_value, context)
                    else:
                        value = field.sync_pipeline(raw_value, context)
                except ValidationError as error:
                    add_error(errors, error.field or field.load_from, error)
                else:
                    setattr(instance, field.load_into, value)
            elif not field.required:
                setattr(instance, field.load_into, field.default() if field.default_callable else field.default)
            else:
                add_error(errors, field.load_from, ValidationError(error_code=Messages.MISSING_REQUIRED_FIELD))
        if errors:
            raise InvalidSchema(translate_errors(errors, language))
        await instance.after_load()
        return instance

    @classmethod
    async def load_form(cls, request: Request, language: dict=EnglishLanguage, context: dict=None):
        """

        :param context:
        :param request:
        :param language:
        :return:
        """
        return await cls.load(await request.form(), language=language, context=context)

    @classmethod
    async def load_json(cls, request: Request, language: dict = EnglishLanguage, context: dict=None):
        """

        :param context:
        :param request:
        :param language:
        :return:
        """
        return await cls.load(await request.json(), language=language, context=context)

    @classmethod
    async def load_query(cls, request: Request, language: dict=EnglishLanguage,
                         context: dict=None, dict path_values=None):
        """Loads fields declared with ``source=QUERY`` (and optionally
        ``source=PATH``) from the URL query string."""
        query_values = _flatten_params(request.args.values)
        sources = {QUERY: query_values, BODY: {}}
        if path_values is not None:
            sources[PATH] = path_values
        return await cls.load(query_values, language=language, context=context, sources=sources)

    @classmethod
    async def load_path(cls, request: Request, language: dict=EnglishLanguage,
                        context: dict=None, dict path_values=None,
                        bint include_query=False):
        """Loads fields declared with ``source=PATH`` from the route
        parameters. Path parameters are injected into the route handler as
        keyword arguments by the router, so forward them through
        ``path_values``. Query-sourced fields are supported when
        ``include_query`` is True."""
        path_values = path_values or {}
        sources = {PATH: path_values, BODY: {}}
        if include_query:
            sources[QUERY] = _flatten_params(request.args.values)
        return await cls.load(path_values, language=language, context=context, sources=sources)

    @classmethod
    async def load_request(cls, request: Request, language: dict=EnglishLanguage,
                           context: dict=None, dict path_values=None):
        """Routes every field automatically based on its declared ``source``
        attribute: body (JSON or multipart form), URL query string or path
        parameters."""
        content_type = request.headers.get('Content-Type') or ''
        if 'multipart/form-data' in content_type:
            body_values = await request.form()
        elif content_type:
            body_values = await request.json()
        else:
            body_values = {}
        query_values = _flatten_params(request.args.values)
        sources = {
            BODY: body_values,
            QUERY: query_values,
            PATH: path_values or {}
        }
        return await cls.load(body_values, language=language, context=context, sources=sources)

    async def after_load(self):
        """

        :return:
        """
        pass
