import os
import mimetypes
from ..exceptions import ValidationError, NestedValidationError
from ..messages import Messages
from ...multipart import UploadedFile, DiskFile
from .validator cimport Validator


class FileMessages:
    NOT_A_FILE = 100
    MIME_TYPE_NOT_ALLOWED = 101
    FILE_TOO_LARGE = 102


FileLanguage = {
    FileMessages.NOT_A_FILE: 'Value is not an uploaded file.',
    FileMessages.MIME_TYPE_NOT_ALLOWED: 'MIME type "{content_type}" is not allowed.',
    FileMessages.FILE_TOO_LARGE: 'File exceeds the maximum allowed size of {maximum_size} byte(s).'
}


cdef str SOURCE_AUTO = 'auto'
cdef str SOURCE_JSON = 'json'
cdef str SOURCE_FORM = 'form'
cdef str SOURCE_QUERY = 'query'
cdef str SOURCE_PATH = 'path'


class Sources:
    AUTO = SOURCE_AUTO
    JSON = SOURCE_JSON
    FORM = SOURCE_FORM
    QUERY = SOURCE_QUERY
    PATH = SOURCE_PATH


Location = Sources


cdef class Field:
    def __init__(self, bint required=True, object default=None, list validators=None,
                 bint strict=False, str load_from=None, str source=Sources.AUTO):
        self.validators = validators or []
        self.strict = strict
        self.is_async = False
        self.load_from = load_from
        self.load_into = None
        self.default = default
        self.required = required if default is None else False
        self.default_callable = callable(self.default)
        self.source = source

    cdef load(self, value):
        return value

    async def pipeline(self, value, context: dict):
        """

        :param context:
        :param value:
        :return:
        """
        value = self.load(value)
        if self.validators:
            await self._call_validators(value, context)
        return value

    cdef sync_pipeline(self, value, dict context):
        """

        :param context:
        :param value:
        :return:
        """
        value = self.load(value)
        if self.validators:
            self._call_sync_validators(value, context)
        return value

    async def _call_validators(self, value, context: dict):
        """

        :param value:
        :param context:
        :return:
        """
        cdef Validator validator
        for validator in self.validators:
            if validator.is_async:
                await validator.validate(value, context)
            else:
                validator.validate(value, context)

    cdef _call_sync_validators(self, value, context: dict):
        """

        :param value:
        :param context:
        """
        cdef Validator validator
        for validator in self.validators:
            validator.validate(value, context)


cdef class String(Field):

    cdef load(self, value):
        """

        :param value:
        :return:
        """
        if isinstance(value, str):
            return value
        elif self.strict and not isinstance(value, (int, float)):
            raise ValidationError(error_code=Messages.MUST_BE_STRING)
        return str(value)


cdef class Integer(Field):

    cdef load(self, value):
        """

        :param value:
        :return:
        """
        if isinstance(value, int):
            return value
        elif self.strict and not isinstance(value, (str, float)):
            raise ValidationError(error_code=Messages.MUST_BE_INTEGER, field=self.load_from)
        try:
            return int(value)
        except ValueError:
            raise ValidationError(error_code=Messages.MUST_BE_INTEGER, field=self.load_from)


cdef class Number(Field):

    cdef load(self, value):
        """

        :param value:
        :return:
        """
        if isinstance(value, int):
            return value
        elif self.strict:
            raise ValidationError(error_code=Messages.MUST_BE_NUMBER, field=self.load_from)
        try:
            return float(value)
        except ValueError:
            raise ValidationError(error_code=Messages.MUST_BE_NUMBER, field=self.load_from)


cdef class List(Field):

    def __init__(self, field, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.field = field

    async def pipeline(self, value, context):
        """

        :param value:
        :return:
        """
        if not isinstance(value, list):
            raise ValidationError(Messages.MUST_BE_LIST)
        processed_list = []
        for index, item in enumerate(value):
            try:
                if self.field.is_async:
                    processed_list.append(await self.field.async_pipeline(item))
                else:
                    processed_list.append(self.field.pipeline(item))
            except ValidationError as error:
                raise ValidationError(f'{index}º element: {error.msg}', field=self.load_from)
        value = processed_list
        if self.validators:
            await self._call_validators(value, context)
        return value


cdef class Nested(Field):

    def __init__(self, schema, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.schema = schema

    async def pipeline(self, value, context: dict):
        """

        :param context:
        :param value:
        :return:
        """
        if not isinstance(value, dict):
            raise ValidationError(error_code=Messages.MUST_BE_DICT, field=self.load_from)
        nested_context = await self.schema.load(value, silent=True)
        if nested_context.errors:
            raise NestedValidationError(context=nested_context.context)
        value = nested_context.data
        if self.validators:
            await self._call_validators(value, context)
        return value

    cdef sync_pipeline(self, value, dict context):
        """

        :param context:
        :param value:
        :return:
        """
        if not isinstance(value, dict):
            raise ValidationError(error_code=Messages.MUST_BE_DICT, field=self.load_from)
        nested_context = self.schema.load(value, silent=True)
        if nested_context.errors:
            raise NestedValidationError(context=nested_context.context)
        value = nested_context.data
        if self.validators:
            self._call_sync_validators(value, context)
        return value


class FileInfo:
    """Metadata and content stream wrapper for an uploaded file."""

    def __init__(self, uploaded_file, size: int, content_type: str):
        self.file = uploaded_file
        self.filename = getattr(uploaded_file, 'filename', None)
        self.content_type = content_type
        self.size = size

    async def read(self, int size=0) -> bytes:
        return await self.file.read(size)

    async def save(self, str destination):
        return await self.file.save(destination)

    def seek(self, pos):
        return self.file.seek(pos)




cdef class File(Field):
    """File field for multipart/form-data uploads.

    Validates the uploaded MIME type against an optional white list and
    enforces a maximum size in bytes.
    """

    def __init__(self, allowed_mime_types=None, int max_size=0, *args, **kwargs):
        kwargs.setdefault('source', Sources.FORM)
        super().__init__(*args, **kwargs)
        self.allowed_mime_types = tuple(allowed_mime_types) if allowed_mime_types else None
        self.max_size = max_size

    cdef str _check_type(self, value):
        if not isinstance(value, UploadedFile):
            raise ValidationError('Value is not an uploaded file.',
                                  field=self.load_from, error_code=FileMessages.NOT_A_FILE)
        content_type = getattr(value, 'content_type', None)
        if not content_type:
            guessed, _ = mimetypes.guess_type(getattr(value, 'filename', '') or '')
            content_type = guessed or 'application/octet-stream'
        if self.allowed_mime_types and content_type not in self.allowed_mime_types:
            raise ValidationError(
                f'MIME type "{content_type}" is not allowed. Allowed types: '
                f'{", ".join(self.allowed_mime_types)}.',
                field=self.load_from, error_code=FileMessages.MIME_TYPE_NOT_ALLOWED,
                content_type=content_type, allowed_mime_types=self.allowed_mime_types
            )
        return content_type

    cdef _check_size(self, int size):
        if self.max_size and size > self.max_size:
            raise ValidationError(
                f'File exceeds the maximum allowed size of {self.max_size} byte(s).',
                field=self.load_from, error_code=FileMessages.FILE_TOO_LARGE, size=size,
                maximum_size=self.max_size
            )

    async def pipeline(self, value, context: dict):
        content_type = self._check_type(value)
        size = await self._resolve_size(value)
        self._check_size(size)
        value.seek(0)
        result = FileInfo(value, size=size, content_type=content_type)
        if self.validators:
            await self._call_validators(result, context)
        return result

    cdef sync_pipeline(self, value, dict context):
        content_type = self._check_type(value)
        size = self._resolve_size_sync(value)
        self._check_size(size)
        value.seek(0)
        result = FileInfo(value, size=size, content_type=content_type)
        if self.validators:
            self._call_sync_validators(result, context)
        return result

    async def _resolve_size(self, value) -> int:
        if isinstance(value, DiskFile):
            return self._disk_size(value)
        return len(await value.read())

    cdef int _resolve_size_sync(self, value):
        if isinstance(value, DiskFile):
            return self._disk_size(value)
        return 0

    cdef int _disk_size(self, value):
        try:
            return os.path.getsize(value.temporary_path)
        except OSError:
            return 0
