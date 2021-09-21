/*
 *
 *  Copyright (c) 2020-2021, NVIDIA CORPORATION.
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 *
 */

package ai.rapids.cudf;

/**
 * Hash algorithm identifiers, mirroring native enum cudf::hash_id
 */
public enum HashType {
  IDENTITY(0),
  MURMUR3(1),
  HASH_MD5(2),
  HASH_SERIAL_MURMUR3(3),
  HASH_SPARK_MURMUR3(4),
  HASH_SHA1(5),
  HASH_SHA224(6),
  HASH_SHA256(7),
  HASH_SHA384(8),
  HASH_SHA512(9);

  private static final HashType[] HASH_TYPES = HashType.values();
  final int nativeId;

  HashType(int nativeId) {
    this.nativeId = nativeId;
  }

  public int getNativeId() {
    return nativeId;
  }

  public static HashType fromNative(int nativeId) {
    for (HashType type : HASH_TYPES) {
      if (type.nativeId == nativeId) {
        return type;
      }
    }
    throw new IllegalArgumentException("Could not translate " + nativeId + " into a HashType");
  }
}
