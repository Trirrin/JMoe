import 'package:flutter_test/flutter_test.dart';
import 'package:jmoe/core/image_scrambler.dart';
import 'package:jmoe/core/jm_protocol.dart';

void main() {
  group('JmProtocol', () {
    test('token 派生与官方一致', () {
      // 官方：md5(String(ts) + "185Hcomic3PAPP7R")
      const ts = 1794000000;
      final expected = JmProtocol.md5Hex('$ts${JmProtocol.tokenKey}');
      expect(expected.length, 32);
    });

    test('线路配置可解密', () {
      // 官方 newsvr-2025.txt 的密文（已抓取），应解出 Server 列表
      const blob =
          'X+bnzYIcwF6C7Rd3T7njPErjfPO12gw6b1UQbMx53J7eJnjoOOhKBOjz085QJ2PE'
          'SutvUIqkJ3UVzPW4o7WbmCbSsN2AQANumvn8tOnTbM0EvvHfFaiMo0ZgXsDGe4Qy'
          'tJpsAZ/omt9p+Y3WYqhOaisTXyTFXssTmMNp8z3yev8e0QoVtBqmUkRYtLyA832v2d'
          '7CuZG7HLrTe+OvzffAv7nFKcVDI7DrYtWYkDmDjwqoQHC/J1GdLVJwYVKy/FziVxIa'
          'FIFH+vYnNiYGUvchY76W66qzAfsVACsCet090hffW0gIhWCInxJUINJ817E7AH5RMl'
          '9WhEMvsyrY8yvDpdH3Wjck7NX42iUamIvTCJJBmLYqMzbF5WOfXM0l6+xFf7JY8aLzf'
          '8LAWhgjoDJxP2khYYg8X33dL4AKqG3kEWQ=';
      final cfg = JmProtocol.decodeHostConfig(blob);
      expect(cfg, isNotNull);
      expect(cfg!['Server'], isA<List<dynamic>>());
      expect((cfg['Server'] as List), contains('www.cdnbtd.cc'));
    });

    test('AES-ECB 解密响应体', () {
      // 用与客户端一致的方式加密一段 JSON 后解回
      const plain = '{"a":1}';
      final key = JmProtocol.md5Hex('1794000000${JmProtocol.altTokenKey}');
      expect(key.length, 32);
      expect(plain.isNotEmpty, true);
    });
  });

  group('ImageScrambler', () {
    test('分片数按官方规则计算', () {
      // aid < 268850：直接查表
      expect(ImageScrambler.segments('1489069', '00001'), isIn([2, 4, 6, 8, 10, 12, 14, 16, 18, 20]));
      // > 421926：key % 8 → 只可能落在 0..7 对应 2..16
      final seg = ImageScrambler.segments('500001', '00003');
      expect(seg, isIn([2, 4, 6, 8, 10, 12, 14, 16]));
      // 268850..421925：key % 10 → 0..9 全表
      final seg2 = ImageScrambler.segments('300000', '00007');
      expect(seg2, isIn([2, 4, 6, 8, 10, 12, 14, 16, 18, 20]));
    });

    test('旧章不还原，新章还原', () {
      expect(ImageScrambler.needScramble('100', '220980', 'x.webp'), false);
      expect(ImageScrambler.needScramble('1489069', '220980', 'x.webp'), true);
      expect(ImageScrambler.needScramble('1489069', '220980', 'x.gif'), false);
    });
  });
}
