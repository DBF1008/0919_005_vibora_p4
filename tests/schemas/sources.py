from vibora import Vibora
from vibora.multipart import FileUpload
from vibora.request import Request
from vibora.responses import JsonResponse
from vibora.schemas import Schema, fields
from vibora.schemas.exceptions import InvalidSchema
from vibora.tests import TestSuite


class QuerySchemaTestCase(TestSuite):

    async def test_load_query_extracts_fields_from_query_string(self):
        class SearchSchema(Schema):
            query: str = fields.String(source=fields.QUERY)
            page: int = fields.Integer(required=False, default=1, source=fields.QUERY)

        app = Vibora()

        @app.route('/search')
        async def search(request: Request):
            data = await SearchSchema.load_query(request)
            return JsonResponse({'query': data.query, 'page': data.page})

        async with app.test_client() as client:
            response = await client.get('/search?query=vibora&page=3')
            self.assertEqual(response.status_code, 200)
            self.assertDictEqual(response.json(), {'query': 'vibora', 'page': 3})

    async def test_load_query_missing_required_field(self):
        class SearchSchema(Schema):
            query: str = fields.String(source=fields.QUERY)

        app = Vibora()

        @app.route('/search')
        async def search(request: Request):
            try:
                await SearchSchema.load_query(request)
            except InvalidSchema:
                return JsonResponse({'ok': False}, status_code=400)
            return JsonResponse({'ok': True})

        async with app.test_client() as client:
            response = await client.get('/search')
            self.assertEqual(response.status_code, 400)

    async def test_query_field_is_not_taken_from_body(self):
        class SearchSchema(Schema):
            query: str = fields.String(source=fields.QUERY)

        try:
            await SearchSchema.load(
                {'query': 'from-body'},
                sources={fields.QUERY: {}, fields.BODY: {'query': 'from-body'}}
            )
            self.fail('Query-sourced field must not be read from the body source.')
        except InvalidSchema as error:
            self.assertIn('query', error.errors)

    async def test_load_from_is_respected_inside_query_source(self):
        class SearchSchema(Schema):
            term: str = fields.String(load_from='q', source=fields.QUERY)

        data = await SearchSchema.load(
            {}, sources={fields.QUERY: {'q': 'vibora'}, fields.BODY: {}}
        )
        self.assertEqual(data.term, 'vibora')


class PathSchemaTestCase(TestSuite):

    async def test_load_path_extracts_route_parameters(self):
        class UserSchema(Schema):
            user_id: int = fields.Integer(source=fields.PATH)

        app = Vibora()

        @app.route('/users/<user_id>')
        async def details(request: Request, user_id: int):
            data = await UserSchema.load_path(request, path_values={'user_id': user_id})
            return JsonResponse({'user_id': data.user_id})

        async with app.test_client() as client:
            response = await client.get('/users/42')
            self.assertEqual(response.status_code, 200)
            self.assertDictEqual(response.json(), {'user_id': 42})

    async def test_load_path_with_query_params(self):
        class UserArticlesSchema(Schema):
            user_id: int = fields.Integer(source=fields.PATH)
            tag: str = fields.String(required=False, source=fields.QUERY)

        app = Vibora()

        @app.route('/users/<user_id>/articles')
        async def articles(request: Request, user_id: int):
            data = await UserArticlesSchema.load_path(
                request, path_values={'user_id': user_id}, include_query=True
            )
            return JsonResponse({'user_id': data.user_id, 'tag': data.tag})

        async with app.test_client() as client:
            response = await client.get('/users/7/articles?tag=python')
            self.assertEqual(response.status_code, 200)
            self.assertDictEqual(response.json(), {'user_id': 7, 'tag': 'python'})


class LoadRequestTestCase(TestSuite):

    async def test_load_request_routes_body_query_and_path(self):
        class CommentSchema(Schema):
            post_id: int = fields.Integer(source=fields.PATH)
            author: str = fields.String(source=fields.QUERY)
            content: str = fields.String(source=fields.BODY)

        app = Vibora()

        @app.route('/posts/<post_id>/comments', methods=['POST'])
        async def create_comment(request: Request, post_id: int):
            data = await CommentSchema.load_request(
                request, path_values={'post_id': post_id}
            )
            return JsonResponse({
                'post_id': data.post_id,
                'author': data.author,
                'content': data.content
            })

        async with app.test_client() as client:
            response = await client.post(
                '/posts/9/comments?author=ann', json={'content': 'hello'}
            )
            self.assertEqual(response.status_code, 200)
            self.assertDictEqual(
                response.json(),
                {'post_id': 9, 'author': 'ann', 'content': 'hello'}
            )

    async def test_legacy_load_without_sources_remains_unchanged(self):
        class PlainSchema(Schema):
            name: str = fields.String()

        data = await PlainSchema.load({'name': 'bob'})
        self.assertEqual(data.name, 'bob')


class FileFieldTestCase(TestSuite):

    async def test_file_upload_happy_path(self):
        class UploadSchema(Schema):
            avatar: object = fields.File(
                allowed_mime_types=['image/png'], max_size=1024 * 1024
            )

        app = Vibora()

        @app.route('/upload', methods=['POST'])
        async def upload(request: Request):
            data = await UploadSchema.load_form(request)
            return JsonResponse({
                'filename': data.avatar.filename,
                'size': data.avatar.size,
                'content_type': data.avatar.content_type
            })

        async with app.test_client() as client:
            response = await client.post(
                '/upload',
                form={'avatar': FileUpload(name='avatar.png', content=b'\x89PNG\r\n' + b'x' * 100)}
            )
            self.assertEqual(response.status_code, 200)
            body = response.json()
            self.assertEqual(body['filename'], 'avatar.png')
            self.assertEqual(body['size'], 106)
            self.assertEqual(body['content_type'], 'image/png')

    async def test_file_mime_type_rejected(self):
        class UploadSchema(Schema):
            avatar: object = fields.File(allowed_mime_types=['image/png'])

        app = Vibora()

        @app.route('/upload', methods=['POST'])
        async def upload(request: Request):
            try:
                await UploadSchema.load_form(request)
            except InvalidSchema as error:
                return JsonResponse(error.errors, status_code=400)
            return JsonResponse({})

        async with app.test_client() as client:
            response = await client.post(
                '/upload',
                form={'avatar': FileUpload(name='virus.exe', content=b'MZ')}
            )
            self.assertEqual(response.status_code, 400)
            self.assertIn('avatar', response.json())
            self.assertIn('not allowed', response.json()['avatar'][0]['msg'])

    async def test_file_too_large_rejected(self):
        class UploadSchema(Schema):
            avatar: object = fields.File(
                allowed_mime_types=['image/png'], max_size=10
            )

        app = Vibora()

        @app.route('/upload', methods=['POST'])
        async def upload(request: Request):
            try:
                await UploadSchema.load_form(request)
            except InvalidSchema as error:
                return JsonResponse(error.errors, status_code=400)
            return JsonResponse({})

        async with app.test_client() as client:
            response = await client.post(
                '/upload',
                form={'avatar': FileUpload(name='big.png', content=b'\x89PNG' + b'x' * 100)}
            )
            self.assertEqual(response.status_code, 400)
            self.assertIn('maximum allowed size', response.json()['avatar'][0]['msg'])

    async def test_non_file_value_rejected(self):
        class UploadSchema(Schema):
            avatar: object = fields.File()

        try:
            await UploadSchema.load({'avatar': 'plain-text'})
            self.fail('A plain string must not pass through the File field.')
        except InvalidSchema as error:
            self.assertIn('multipart/form-data', error.errors['avatar'][0]['msg'])

    async def test_optional_file_defaults_to_none(self):
        class UploadSchema(Schema):
            avatar: object = fields.File(required=False)

        data = await UploadSchema.load({})
        self.assertIsNone(data.avatar)

    async def test_invalid_mime_whitelist_argument(self):
        with self.assertRaises(ValueError):
            fields.File(allowed_mime_types=['not-a-mime'])
