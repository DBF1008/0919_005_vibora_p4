from asyncio import iscoroutinefunction
from typing import List as TList, Dict
from vibora.request import Request
from collections import defaultdict
from .validator import Validator
from .fields cimport Field, String, Integer, Number, Nested, List, File
from .fields import Sources, FileLanguage
from ..messages import Messages, EnglishLanguage
from ..exceptions import ValidationError, InvalidSchema


optimized_fields = (String, Integer, List, Number, Nested, File)
type_index = {str: String, int: Integer, float: Number, TList: List}


def get_namespace_annotations(namespace: dict):
    """

    Retrieves evaluated class annotations in a way compatible with both
    legacy Pythons and PEP 649 (lazy annotations, Python 3.14+).
    :param namespace:
    :return:
    """
    annotations = namespace.get('__annotations__')
    if annotations is not None:
        return annotations
    annotate_function = namespace.get('__annotate_func__')
    if annotate_function is not None:
        try:
            return annotate_function(1)
        except Exception:
            return {}
    return {}


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
        annotations = get_namespace_annotations(args[2])

        # Parsing declared fields.
        for attribute_name, value in args[2].items():
            if isinstance(value, Field):
                if attribute_name not in annotations:
                    raise SyntaxError(f'Attribute "{attribute_name}" of class "{args[0]}" is missing a type hint. ')
                fields[attribute_name] = SchemaCreator.prepare_field(value, attribute_name)
            elif not attribute_name.startswith('_') and attribute_name in annotations:
                chosen_type = annotations[attribute_name]
                if isinstance(chosen_type, Field):
                    new_field = chosen_type
                    new_field.default = value
                    new_field.required = False
                else:
                    new_field = type_index[chosen_type](default=value, required=False)
                fields[attribute_name] = SchemaCreator.prepare_field(new_field, attribute_name)

        # Looking for named vars.
        for name, type_ in annotations.items():
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
    async def load(cls, values, language=EnglishLanguage, dict context=None) -> 'Schema':
        """

        Core entry point. Accepts either a raw mapping (legacy behavior) or a
        Request instance, in which case values are routed from the request
        according to each field's source configuration.
        :param values:
        :param language:
        :param context:
        :return:
        """
        if isinstance(values, Request):
            return await cls.load_request(values, language=language, context=context)

        def resolve(field: Field):
            if field.load_from in values:
                return True, values[field.load_from]
            return False, None

        return await cls._run(resolve, language=language, context=context)

    @classmethod
    async def load_request(cls, request: Request, language=EnglishLanguage,
                           dict context=None) -> 'Schema':
        """

        Loads a schema directly from a Request. The primary input source is
        inferred from the Content-Type header. Fields may override their
        source individually.
        :param request:
        :param language:
        :param context:
        :return:
        """
        default_source = cls._detect_default_source(request)
        return await cls._load_from_request(
            request, default_source=default_source, language=language, context=context
        )

    @classmethod
    async def load_form(cls, request: Request, language=EnglishLanguage, context: dict=None):
        """

        :param context:
        :param request:
        :param language:
        :return:
        """
        return await cls._load_from_request(
            request, default_source=Sources.FORM, language=language, context=context
        )

    @classmethod
    async def load_json(cls, request: Request, language=EnglishLanguage, context: dict=None):
        """

        :param context:
        :param request:
        :param language:
        :return:
        """
        return await cls._load_from_request(
            request, default_source=Sources.JSON, language=language, context=context
        )

    @classmethod
    async def load_query(cls, request: Request, language=EnglishLanguage, context: dict=None):
        """

        Binds URL query string parameters (?name=value) to the schema fields.
        :param context:
        :param request:
        :param language:
        :return:
        """
        return await cls._load_from_request(
            request, default_source=Sources.QUERY, language=language, context=context
        )

    @classmethod
    async def load_path(cls, request: Request, dict path_params=None,
                        language=EnglishLanguage, dict context=None):
        """

        Binds dynamic route path parameters to the schema fields. Path params
        can be supplied directly or through context['path_params'].
        :param request:
        :param path_params:
        :param language:
        :param context:
        :return:
        """
        if context is None:
            context = {}
        if path_params:
            context['path_params'] = path_params
        return await cls._load_from_request(
            request, default_source=Sources.PATH, language=language, context=context
        )

    @staticmethod
    def _detect_default_source(request: Request) -> str:
        content_type = request.headers.get('Content-Type') or ''
        if 'multipart/form-data' in content_type or \
                'application/x-www-form-urlencoded' in content_type:
            return Sources.FORM
        return Sources.JSON

    @staticmethod
    def _query_values(request: Request) -> dict:
        values = {}
        for key, raw_values in request.args.values.items():
            if isinstance(key, bytes):
                key = key.decode('utf-8')
            value = raw_values[0] if isinstance(raw_values, list) and raw_values else raw_values
            if isinstance(value, bytes):
                value = value.decode('utf-8')
            values[key] = value
        return values

    @classmethod
    async def _load_from_request(cls, request: Request, str default_source,
                                 dict language, dict context):
        if context is None:
            context = {}

        required_sources = set()
        for field in cls._fields:
            required_sources.add(
                default_source if field.source == Sources.AUTO else field.source
            )

        json_values = None
        form_values = None
        query_values = None
        if Sources.JSON in required_sources:
            json_values = await request.json()
        if Sources.FORM in required_sources:
            form_values = await request.form()
        if Sources.QUERY in required_sources:
            query_values = cls._query_values(request)

        path_values = context.get('path_params', {}) or {}
        source_values = {
            Sources.JSON: json_values,
            Sources.FORM: form_values,
            Sources.QUERY: query_values,
            Sources.PATH: path_values
        }

        def resolve(field: Field):
            source = default_source if field.source == Sources.AUTO else field.source
            bucket = source_values.get(source)
            if bucket is not None and field.load_from in bucket:
                return True, bucket[field.load_from]
            return False, None

        return await cls._run(resolve, language=language, context=context)

    @classmethod
    async def _run(cls, resolver, object language=EnglishLanguage, dict context=None) -> 'Schema':
        """

        :param resolver:
        :param language:
        :param context:
        :return:
        """
        cdef Field field
        cdef dict errors
        if context is None:
            context = {}
        resolved_language = dict(language)
        resolved_language.update(FileLanguage)
        instance = cls(silent=True)
        errors = {}
        for field in cls._fields:
            exists, raw_value = resolver(field)
            if exists:
                try:
                    if field.is_async or isinstance(field, File):
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
            raise InvalidSchema(translate_errors(errors, resolved_language))
        await instance.after_load()
        return instance

    async def after_load(self):
        """

        :return:
        """
        pass
