// Argon2id and BLAKE2b against answers from the code the browser runs: the constants came out of
// @noble/hashes 1.8.0 under node, with the inputs written beside them, and all but the first also
// match Go's golang.org/x/crypto/argon2. RFC 9106's own test vector (section 5.3) is the first
// entry, and noble gives the same tag for it.

import Foundation
import Testing
@testable import DMCNKit

@Suite struct BLAKE2bTests {
    /// RFC 7693 appendix A.
    @Test func theRFCExample() {
        #expect(
            BLAKE2b.hash(Data("abc".utf8), length: 64).hex
                == "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1"
                + "7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
    }

    /// Lengths either side of the 128-byte block, where the last-block handling lives, and the
    /// digest length, which changes the hash rather than truncating it.
    @Test(
        arguments: [
            (
                0, 64,
                "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce"
            ),
            (
                1, 64,
                "2fa3f686df876995167e7c2e5d74c4c7b6e48f8068fe0e44208344d480f7904c36963e44115fe3eb2a3ac8694c28bcb4f5a0f3276f2e79487d8219057a506e4b"
            ),
            (
                3, 64,
                "40a374727302d9a4769c17b5f409ff32f58aa24ff122d7603e4fda1509e919d4107a52c57570a6d94e50967aea573b11f86f473f537565c66f7039830a85d186"
            ),
            (
                111, 64,
                "bf23c0c25c8060e4f6995f1623a3bebecaa96e308680000a8aa3cd56bb1a6da099e10d9231b37f4519b2efd2c24de72f31a5f19535241b4a59fa3c03ceb790e7"
            ),
            (
                112, 64,
                "877fd652c05281009c0a5250e7a3a671f8b18c108817fe4a874de22da8e45db11958a600c5f62e67d36cbf84474cf244a9c2b03a9fb9dc711cd1a2cab6f3fae0"
            ),
            (
                127, 64,
                "b6292669ccd38d5f01caae96ba272c76a879a45743afa0725d83b9ebb26665b731f1848c52f11972b6644f554c064fa90780dbbbf3a89d4fc31f67df3e5857ef"
            ),
            (
                128, 64,
                "2319e3789c47e2daa5fe807f61bec2a1a6537fa03f19ff32e87eecbfd64b7e0e8ccff439ac333b040f19b0c4ddd11a61e24ac1fe0f10a039806c5dcc0da3d115"
            ),
            (
                129, 64,
                "f59711d44a031d5f97a9413c065d1e614c417ede998590325f49bad2fd444d3e4418be19aec4e11449ac1a57207898bc57d76a1bcf3566292c20c683a5c4648f"
            ),
            (
                255, 64,
                "5b21c5fd8868367612474fa2e70e9cfa2201ffeee8fafab5797ad58fefa17c9b5b107da4a3db6320baaf2c8617d5a51df914ae88da3867c2d41f0cc14fa67928"
            ),
            (
                256, 64,
                "1ecc896f34d3f9cac484c73f75f6a5fb58ee6784be41b35f46067b9c65c63a6794d3d744112c653f73dd7deb6666204c5a9bfa5b46081fc10fdbe7884fa5cbf8"
            ),
            (
                257, 64,
                "d8bfe068de0b4f9fa876a3f8024eb9f7b0029fd5dcf251199e065cee89e1a282c8dbf0442f2ade7294ac1c6be19b388dc990c34d8cb79f5f10c54fa813834fda"
            ),
            (
                1000, 64,
                "9fe687126e6566313081b43167cbfa0b4f721b45a5afd4076af327765d63a616478ffbd1cd5fbe4033e8638b8bcf8de6b3978b54a30f1d9d8d68fbe66c2b74cf"
            ),
            (3, 32, "3d8c3d594928271f44aad7a04b177154806867bcf918e1549c0bc16f9da2b09b"),
            (
                128, 48,
                "a2c2acf7ce4079c02b7f38e2ef33bff531a31a7c7effe712c5348b4d616c0cba9b152679317984ec632d0c70eb11eece"
            ),
            (200, 1, "5f"),
            (200, 33, "0e05b1cffd648eb8451fdf00b738a05bf3082f9a3edae234ff675f0cad4ab70d7d"),
            (
                200, 63,
                "07757495872687192c2be9b3c255dedfeec4035f29171d4a382f57a6dfd64e019ee8da8914ba78c0be5e54b1c9b90d2c71b28dae6af4c4d81b250aa2edaaac"
            ),
        ] as [(Int, Int, String)])
    func matchesNoble(inputLength: Int, digestLength: Int, digest: String) {
        #expect(BLAKE2b.hash(pattern(inputLength, from: 0), length: digestLength).hex == digest)
    }
}

@Suite struct Argon2idTests {
    struct Vector: Sendable, CustomTestStringConvertible {
        let name: String
        let password: String
        let salt: String
        let memoryKiB: Int
        let iterations: Int
        let parallelism: Int
        let secret: String
        let associatedData: String
        let tag: String
        var testDescription: String { name }
    }

    static let vectors: [Vector] = [
        Vector(
            name: "rfc9106", password: "0101010101010101010101010101010101010101010101010101010101010101",
            salt: "02020202020202020202020202020202", memoryKiB: 32,
            iterations: 3, parallelism: 4, secret: "0303030303030303", associatedData: "040404040404040404040404",
            tag: "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659"),
        Vector(
            name: "smallest", password: "70617373776f7264", salt: "736f6d6573616c74", memoryKiB: 8,
            iterations: 1, parallelism: 1, secret: "", associatedData: "",
            tag: "f137f8e186a403a679ccd0606e5ab5dcdafe43c1640855ac8c6e33e9bd63eeb3"),
        Vector(
            name: "emptyPassword", password: "", salt: "000102030405060708090a0b0c0d0e0f", memoryKiB: 64,
            iterations: 2, parallelism: 1, secret: "", associatedData: "",
            tag: "27d635f833c91976f01cce988b3019e3b9889f66fe6b9efc7a0ec663c6059d07"),
        Vector(
            name: "unalignedMemory", password: "70617373776f7264", salt: "000102030405060708090a0b0c0d0e0f",
            memoryKiB: 37,
            iterations: 2, parallelism: 2, secret: "", associatedData: "",
            tag: "7c43e9c3afc784db3a7f17eea194a6693c38c90b3beca9e54c10596b55225caa"),
        Vector(
            name: "fourByteTag", password: "70617373776f7264", salt: "000102030405060708090a0b0c0d0e0f", memoryKiB: 32,
            iterations: 1, parallelism: 1, secret: "", associatedData: "",
            tag: "eca2eef0"),
        Vector(
            name: "tag64", password: "70617373776f7264", salt: "000102030405060708090a0b0c0d0e0f", memoryKiB: 32,
            iterations: 1, parallelism: 1, secret: "", associatedData: "",
            tag:
                "79ae6e1658e739399d625a088c77a17b7140577a3ff7697e4247ecfa780601890741f50da009ae58aef26c3c03b718d2b0930be85ad1febf2d5759b8d125a17b"
        ),
        // From Go's golang.org/x/crypto/argon2, not noble: noble 1.8.0 returns only 64 bytes when
        // asked for 65, because it views the output as 32-bit words. The browser asks for 32, so
        // it never sees this, and the first 64 bytes agree.
        Vector(
            name: "tag65", password: "70617373776f7264", salt: "000102030405060708090a0b0c0d0e0f", memoryKiB: 32,
            iterations: 1, parallelism: 1, secret: "", associatedData: "",
            tag:
                "8781af100556c1c26ebe9d8619fd056245ca637c0d450295ab2bb239509d6102bb4e70bc98880a4dc856746197395abfefa6db173241cdf377b5063ed92fc1d046"
        ),
        Vector(
            name: "tag100", password: "70617373776f7264", salt: "000102030405060708090a0b0c0d0e0f", memoryKiB: 32,
            iterations: 1, parallelism: 1, secret: "", associatedData: "",
            tag:
                "b7e56ede87b269d5e41a93404a479224f575c0eaaadf76a3a7c59fae95755956cf13cbac806d59c426943cc0fd9c9a0bc3d6921d3da9284345742d217b92550248d62608c7ded8b858e1bcc470d55ac2695e723212e21eac04f8dd8bc2c710cf3d5768f2"
        ),
        Vector(
            name: "tag1024", password: "70617373776f7264", salt: "000102030405060708090a0b0c0d0e0f", memoryKiB: 32,
            iterations: 1, parallelism: 1, secret: "", associatedData: "",
            tag:
                "e99e5fe216b6167c83bbf06937897b78ad07b2fdef8ea3fb89673db59c4cb1f69ded40e147be28c1f63929107ebb499541c84537278d9da72df73439869b4b7dd2e070f753af5c2b6b8be89917431e64d2010a13f44fb110fbe07ce6b088cc77f0ef4f81960c38eae9fc287061c95361dd1fea10b92f989139e71ab7374cdf97f29fa895ef5860cc58c4caa568e44575d573d9f122dea8cf277c4b7132c2859147ca8ae2c11adc470e2e11f2fce3389e451840f21ce3bab94e5dafb7d78bd1a6a4164de67890df4b8a9e1eb7c997aa4d1d32e4a3ebddc7e8fb8d69892c7d3a5169196fbee3711c371a359b9f96ffd87fee084aa2271f22ead310943c2eac2b186f4ec62429052b3de29e0368e311d2e27f5bfb4e32c0bdb729f8f7d1b5acd22488b67eb12932bc3d8d252e4667c5e01928f221b85a59afd6a20a765af0e917553f8de55f209b46d97751598864c64a7f77e62d8eb4091eba8443c2e4ec1d0ec78bb6772ad7a2a85ccf48a69cbae33502a095edd5c0ddc9c9294237a8e8fc4b6aaac8085940320c822a38d7e9265c0e859a47b56028c7d41d04bbdbe576182b05e7f5db71286b5187cf77162f3fa5a9f9b265231308bd27ce288f0ef93ac17b94dbf9b8b4d5c329bfa47151277646b28c8f1ac15c7f3fd2f899023eb1ee3640ba887c514902e57740579b34e5cf44060ca9a23fbf4f150a8da76b5a784a18d7849d63fa61acf5f29c358719a24dd5d31faa75cc1a049ab7515e5b638ae542f061ab3d51431ee658e00beb19735bd9418b34a71562189c96d33947f82a787317422289ad2234dcae1f28ca7394bba88ca830da059ec708fe0bab6448d3a7ddc602f560203ffc43c5465f824efe9c0d9646fa330f47821f91f389dfa76a598902311a509eb7b5583853c8bce98cd368c837850c18ba59f50280c364e06901e4a1d32ad1af52763f52f85c4f3dfb53f397ee2eb728d79bc07931a3f62aecf627b5a87433b0196c2b7fd5822e0caa21b6491d7e2d53515527b4aecbc48b722528d5800ec986d4234416c7617c39574ddc7b0f912bf92ad5b147468ebbc8018eb60d7e8b0f1ff2107aab68b49e6610a688b0448d58a6d5a4591aa084fd1c07d834840dcdbb0c98c7e02a81a265405af9cc62bcd8ff8ec14fb622092ef61c69d5212a1608e0f143c63af12de58ff049759501ae3f4110ca44fc95bc241b2a1198f7e5df7c9a319070dd6b6d5f0ae31e033a5a3c1cdbf947fa113f3761c4c78b902fab7240add291ed7398ac9bb6b7044c8554a4405b5e51f6f1706ff1567d1ee2a83512bf91c9836f94f3227bf4879cfe41b8c37c830e49309aded103889b0a97277f7ddf270ddf4eb91b0d4917e0981a3609609e6a574927dd5a340fbe9fce76272560f666b8f7cae904805a1c4920c436d132a4d507cdd1970dc675fbb6554c7cb6d3"
        ),
        Vector(
            name: "secondAddressBlock", password: "70617373776f7264",
            salt: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", memoryKiB: 2048,
            iterations: 3, parallelism: 1, secret: "", associatedData: "",
            tag: "9c78b69ec2d1918a0511b4d5e1a69fcce978ef4408d1f3228e322365c09962e6"),
        Vector(
            name: "fourLanes", password: "70617373776f7264",
            salt: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", memoryKiB: 4096,
            iterations: 2, parallelism: 4, secret: "", associatedData: "",
            tag: "1beea00751578066b21c00ff026f45afe5c53e9c61e976b143129b62ff82198f"),
        Vector(
            name: "unicodePassphrase", password: "70c3a4737377c3b6726420e29c9320f09f9491",
            salt: "0708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20212223242526", memoryKiB: 256,
            iterations: 2, parallelism: 1, secret: "", associatedData: "",
            tag: "87fa6b9bce1034477785f342f3a4de497d69caf901788e9f44d7bf8fb1885d20"),
    ]

    /// The browser's actual parameters (keystore.ts ARGON2_PARAMS) on a 32-byte salt.
    static let webVector = Vector(
        name: "webParams", password: "636f727265637420686f727365206261747465727920737461706c65",
        salt: "404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f", memoryKiB: 19456, iterations: 2,
        parallelism: 1, secret: "", associatedData: "",
        tag: "1e10089d37951cd523bb3470f93d9bd05211f251e915b423a9dfa32e0319d0f6")

    static func derive(_ v: Vector) throws -> Data {
        try Argon2id.derive(
            password: unhex(v.password), salt: unhex(v.salt), memoryKiB: v.memoryKiB, iterations: v.iterations,
            parallelism: v.parallelism, length: v.tag.count / 2, secret: unhex(v.secret),
            associatedData: unhex(v.associatedData))
    }

    @Test(arguments: vectors)
    func matchesNoble(_ v: Vector) throws {
        #expect(try Self.derive(v).hex == v.tag)
    }

    @Test func matchesNobleAtTheWebsParameters() throws {
        #expect(try Self.derive(Self.webVector).hex == Self.webVector.tag)
    }

    @Test func theAsyncFormGivesTheSameAnswer() async throws {
        let v = Self.vectors[0]
        let tag = try await Argon2id.derive(
            password: unhex(v.password), salt: unhex(v.salt), memoryKiB: v.memoryKiB, iterations: v.iterations,
            parallelism: v.parallelism, length: 32, secret: unhex(v.secret), associatedData: unhex(v.associatedData))
        #expect(tag.hex == v.tag)
    }

    /// The same limits noble enforces. Passing a bad value through would derive a key the
    /// browser refuses to, and a file only one client can open.
    @Test(
        arguments: [
            (19456, 2, 1, 3, 32),  // length under 4
            (19456, 0, 1, 32, 32),  // no iterations
            (19456, 2, 0, 32, 32),  // no lanes
            (7, 2, 1, 32, 32),  // under 8 KiB
            (31, 2, 4, 32, 32),  // under 8 KiB per lane
            (19456, 2, 1, 32, 7),  // salt under 8 bytes
        ] as [(Int, Int, Int, Int, Int)])
    func refusesWhatNobleRefuses(memory: Int, iterations: Int, lanes: Int, length: Int, saltLength: Int) {
        #expect(throws: Argon2id.InvalidParameters.self) {
            try Argon2id.derive(
                password: Data(), salt: fill(saltLength, 1), memoryKiB: memory, iterations: iterations,
                parallelism: lanes, length: length)
        }
    }
}
