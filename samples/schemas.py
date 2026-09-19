"""
Schema input-source routing and file upload examples.

New features showcased here:
    1) Fields can declare where they must be loaded from using the
       ``source`` argument: ``fields.BODY`` (default, JSON or form),
       ``fields.QUERY`` (URL query string) or ``fields.PATH`` (route params).
    2) ``Schema.load_request(request, path_values=...)`` extracts every field
       automatically from the right input source.
    3) ``Schema.load_query`` and ``Schema.load_path`` are convenience
       factories for query-string and path-parameter schemas.
    4) ``fields.File`` extracts file metadata (filename, size, content type)
       and a content stream from multipart/form-data uploads while enforcing
       a MIME whitelist and a maximum file size.
"""
from vibora import Vibora, Request
from vibora.responses import JsonResponse
from vibora.schemas import Schema, fields
from vibora.schemas.exceptions import InvalidSchema, ValidationError

app = Vibora()


# --------------------------------------------------------------------------
# Classic JSON body schema (backward compatible behaviour).
# --------------------------------------------------------------------------
class BenchmarkSchema(Schema):
    field1: str = fields.String(required=True)
    field2: int = fields.Integer(required=True)


@app.route('/', methods=['POST'])
async def home(request: Request):
    try:
        values = await BenchmarkSchema.load_json(request)
        return JsonResponse({'msg': 'Successfully validated', 'field1': values.field1,
                             'field2': values.field2})
    except InvalidSchema:
        return JsonResponse({'msg': 'Data is invalid'})


# --------------------------------------------------------------------------
# Query-string schema: /search?query=vibora&page=2
# --------------------------------------------------------------------------
class SearchSchema(Schema):
    query: str = fields.String(source=fields.QUERY)
    page: int = fields.Integer(required=False, default=1, source=fields.QUERY)
    page_size: int = fields.Integer(required=False, default=20, source=fields.QUERY)


@app.route('/search', methods=['GET'])
async def search(request: Request):
    try:
        params = await SearchSchema.load_query(request)
    except InvalidSchema as error:
        return JsonResponse({'errors': error.errors}, status_code=400)
    return JsonResponse({
        'query': params.query,
        'page': params.page,
        'page_size': params.page_size
    })


# --------------------------------------------------------------------------
# Mixed sources: a path parameter plus query-string filters.
# Route path parameters are injected into the handler as keyword arguments,
# forward them to the schema loader.
# --------------------------------------------------------------------------
class UserArticlesSchema(Schema):
    user_id: int = fields.Integer(source=fields.PATH)
    tag: str = fields.String(required=False, source=fields.QUERY)
    limit: int = fields.Integer(required=False, default=10, source=fields.QUERY)


@app.route('/users/<user_id>/articles', methods=['GET'])
async def user_articles(request: Request, user_id: int):
    try:
        params = await UserArticlesSchema.load_path(
            request, path_values={'user_id': user_id}, include_query=True
        )
    except InvalidSchema as error:
        return JsonResponse({'errors': error.errors}, status_code=400)
    return JsonResponse({'user_id': params.user_id, 'tag': params.tag, 'limit': params.limit})


# --------------------------------------------------------------------------
# Multipart file upload schema with MIME whitelist + size limit.
# Uploaded files expose: .filename, .size, .content_type, .read(), .save(),
# .seek() and async chunk iteration through .chunks(size).
# --------------------------------------------------------------------------
class AvatarUploadSchema(Schema):
    title: str = fields.String(source=fields.BODY)
    avatar: object = fields.File(
        allowed_mime_types=['image/png', 'image/jpeg', 'image/gif'],
        max_size=2 * 1024 * 1024  # 2 MB
    )


@app.route('/upload', methods=['POST'])
async def upload_avatar(request: Request):
    try:
        data = await AvatarUploadSchema.load_form(request)
    except InvalidSchema as error:
        return JsonResponse({'errors': error.errors}, status_code=400)
    uploaded = data.avatar
    await uploaded.save('/tmp/' + uploaded.filename)
    return JsonResponse({
        'title': data.title,
        'filename': uploaded.filename,
        'size': uploaded.size,
        'content_type': uploaded.content_type
    })


# --------------------------------------------------------------------------
# Fully automatic source routing from a single call: body + query + path.
# --------------------------------------------------------------------------
class CreateCommentSchema(Schema):
    post_id: int = fields.Integer(source=fields.PATH)
    author: str = fields.String(source=fields.QUERY)
    content: str = fields.String(source=fields.BODY)
    attachment: object = fields.File(
        required=False,
        allowed_mime_types=['application/pdf', 'text/plain'],
        max_size=5 * 1024 * 1024,  # 5 MB
        source=fields.BODY
    )


@app.route('/posts/<post_id>/comments', methods=['POST'])
async def create_comment(request: Request, post_id: int):
    try:
        data = await CreateCommentSchema.load_request(
            request, path_values={'post_id': post_id}
        )
    except InvalidSchema as error:
        return JsonResponse({'errors': error.errors}, status_code=400)

    attachment_meta = None
    if data.attachment is not None:
        # Consume the content stream chunk by chunk without loading it all
        # into memory at once.
        total_bytes = 0
        async for chunk in data.attachment.chunks(64 * 1024):
            total_bytes += len(chunk)
        attachment_meta = {
            'filename': data.attachment.filename,
            'size': data.attachment.size,
            'streamed_bytes': total_bytes,
            'content_type': data.attachment.content_type
        }

    return JsonResponse({
        'post_id': data.post_id,
        'author': data.author,
        'content': data.content,
        'attachment': attachment_meta
    })


if __name__ == '__main__':
    app.run(debug=True, port=8000, host='0.0.0.0')
