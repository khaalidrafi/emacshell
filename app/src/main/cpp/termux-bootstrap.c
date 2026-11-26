#include <jni.h>

extern jbyte blob[];
extern int blob_size;

/* Return a direct ByteBuffer over the .rodata bootstrap zip instead
 * of copying it into a Java byte[]: the copy is what exhausts the
 * heap on low-RAM devices during first-boot extraction.  The Java
 * side only ever reads the buffer (ByteBufferInputStream). */
JNIEXPORT jobject JNICALL Java_com_termux_app_TermuxInstaller_getZip(JNIEnv *env, __attribute__((__unused__)) jobject This)
{
    return (*env)->NewDirectByteBuffer(env, (void *) blob, (jlong) blob_size);
}
