package com.jci.mediaprocessor.media_processor;

import android.opengl.GLES20;
import android.opengl.GLES30;
import android.opengl.GLUtils;
import android.view.Surface;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;

import javax.microedition.khronos.egl.EGL10;
import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.egl.EGLContext;
import javax.microedition.khronos.egl.EGLDisplay;
import javax.microedition.khronos.egl.EGLSurface;

/**
 * Base GLES2/3 renderer that targets a Flutter SurfaceProducer Surface.
 */
public abstract class BaseRenderer {
  static { System.loadLibrary("MediaProcessor"); }

  // Direct buffer (no Java copy) for pointer uploads
  public static native ByteBuffer getBufferDirect(long ptr, int size);

  protected final Surface surface;  // target from SurfaceProducer
  protected int width;
  protected int height;

  protected EGL10 egl;
  protected EGLDisplay eglDisplay;
  protected EGLContext eglContext;
  protected EGLSurface eglSurface;

  protected final int[] vbo = new int[1];
  protected final int[] vao = new int[1];
  protected final int[] ebo = new int[1];

  protected int mProgramHandle;
  protected final int[] mTextures = new int[3];

  /** Attributes */
  protected int mPositionHandle;
  protected int mTexCoordHandle;

  /** Uniform sampler handles (RGB: [0] only; YUV: [0..2]) */
  protected final int[] mYUVTextureHandle = new int[3];

  public BaseRenderer(Surface surface, int width, int height) {
    this.surface = surface;
    this.width = width;
    this.height = height;
  }

  // ----- subclass hooks -----
  protected abstract String vertexShader();
  protected abstract String fragmentShader();
  protected abstract void connectTexturesToProgram();         // bind uniforms
  protected abstract void loadTexture(ByteBuffer[] buffers);   // RGB: [0]; YUV: [0..2]
  protected abstract void drawTexture();                       // issues draw + swap
  public abstract void setBuffer(byte[] inY, byte[] inU, byte[] inV);
  public abstract void setBufferPtr(long ptr, int size);

  // ----- GL setup -----
  public void initGL() {
    egl = (EGL10) EGLContext.getEGL();
    eglDisplay = egl.eglGetDisplay(EGL10.EGL_DEFAULT_DISPLAY);
    if (eglDisplay == EGL10.EGL_NO_DISPLAY) {
      throw new RuntimeException("eglGetDisplay failed");
    }

    int[] version = new int[2];
    if (!egl.eglInitialize(eglDisplay, version)) {
      throw new RuntimeException("eglInitialize failed");
    }

    EGLConfig eglConfig = chooseEglConfig();
    eglContext = createContext(egl, eglDisplay, eglConfig);

    // Create EGL window surface from the Flutter-managed android.view.Surface
    eglSurface = egl.eglCreateWindowSurface(eglDisplay, eglConfig, surface, null);
    if (eglSurface == null || eglSurface == EGL10.EGL_NO_SURFACE) {
      throw new RuntimeException("eglCreateWindowSurface: " + GLUtils.getEGLErrorString(egl.eglGetError()));
    }
    if (!egl.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
      throw new RuntimeException("eglMakeCurrent: " + GLUtils.getEGLErrorString(egl.eglGetError()));
    }

    GLES20.glGenTextures(3, mTextures, 0);
  }

  public void initShaders() {
    int vsh = compile(GLES20.GL_VERTEX_SHADER, vertexShader());
    int fsh = compile(GLES20.GL_FRAGMENT_SHADER, fragmentShader());

    mProgramHandle = GLES20.glCreateProgram();
    GLES20.glAttachShader(mProgramHandle, vsh);
    GLES20.glAttachShader(mProgramHandle, fsh);
    // Bind attribute locations before linking
    GLES20.glBindAttribLocation(mProgramHandle, 0, "a_Position");
    GLES20.glBindAttribLocation(mProgramHandle, 1, "a_TexCoordinate");
    GLES20.glLinkProgram(mProgramHandle);

    int[] link = new int[1];
    GLES20.glGetProgramiv(mProgramHandle, GLES20.GL_LINK_STATUS, link, 0);
    if (link[0] == 0) {
      String log = GLES20.glGetProgramInfoLog(mProgramHandle);
      GLES20.glDeleteProgram(mProgramHandle);
      throw new RuntimeException("Program link failed: " + log);
    }

    mPositionHandle = GLES20.glGetAttribLocation(mProgramHandle, "a_Position");
    mTexCoordHandle = GLES20.glGetAttribLocation(mProgramHandle, "a_TexCoordinate");
    connectTexturesToProgram();
    GLES20.glUseProgram(mProgramHandle);
  }

  public void initBuffers() {
    // Interleaved: pos(x,y,z) + tex(s,t)
    final float[] vertices = new float[] {
        //  x,    y,   z,   s,   t
         1f,  1f,  0f, 1f, 0f,  // top-right
         1f, -1f,  0f, 1f, 1f,  // bottom-right
        -1f, -1f,  0f, 0f, 1f,  // bottom-left
        -1f,  1f,  0f, 0f, 0f,  // top-left
    };
    final int[] indices = new int[] { 0, 1, 2, 0, 2, 3 };

    FloatBuffer vBuffer = ByteBuffer.allocateDirect(vertices.length * Float.BYTES)
        .order(ByteOrder.nativeOrder()).asFloatBuffer();
    vBuffer.put(vertices).position(0);

    IntBuffer iBuffer = ByteBuffer.allocateDirect(indices.length * Integer.BYTES)
        .order(ByteOrder.nativeOrder()).asIntBuffer();
    iBuffer.put(indices).position(0);

    GLES30.glGenVertexArrays(1, vao, 0);
    GLES20.glGenBuffers(1, vbo, 0);
    GLES20.glGenBuffers(1, ebo, 0);

    GLES30.glBindVertexArray(vao[0]);

    GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, vbo[0]);
    GLES20.glBufferData(GLES20.GL_ARRAY_BUFFER, vertices.length * Float.BYTES, vBuffer, GLES20.GL_STATIC_DRAW);

    GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, ebo[0]);
    GLES20.glBufferData(GLES20.GL_ELEMENT_ARRAY_BUFFER, indices.length * Integer.BYTES, iBuffer, GLES20.GL_STATIC_DRAW);

    // a_Position @ location 0 : vec3
    GLES20.glVertexAttribPointer(0, 3, GLES20.GL_FLOAT, false, 5 * Float.BYTES, 0);
    GLES20.glEnableVertexAttribArray(0);

    // a_TexCoordinate @ location 1 : vec2 (offset 3 floats)
    GLES20.glVertexAttribPointer(1, 2, GLES20.GL_FLOAT, false, 5 * Float.BYTES, 3 * Float.BYTES);
    GLES20.glEnableVertexAttribArray(1);

    GLES30.glBindVertexArray(0);
  }

  protected void deinitGL() {
    egl.eglMakeCurrent(eglDisplay, EGL10.EGL_NO_SURFACE, EGL10.EGL_NO_SURFACE, EGL10.EGL_NO_CONTEXT);
    if (eglSurface != null && eglSurface != EGL10.EGL_NO_SURFACE) {
      egl.eglDestroySurface(eglDisplay, eglSurface);
      eglSurface = EGL10.EGL_NO_SURFACE;
    }
    if (eglContext != null) {
      egl.eglDestroyContext(eglDisplay, eglContext);
      eglContext = EGL10.EGL_NO_CONTEXT;
    }
  }

  protected EGLContext createContext(EGL10 egl, EGLDisplay display, EGLConfig cfg) {
    final int EGL_CONTEXT_CLIENT_VERSION = 0x3098;
    int[] attrib = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL10.EGL_NONE };
    return egl.eglCreateContext(display, cfg, EGL10.EGL_NO_CONTEXT, attrib);
  }

  protected EGLConfig chooseEglConfig() {
    int[] spec = {
        0x3040 /*EGL_RENDERABLE_TYPE*/, 4, // EGL_OPENGL_ES2_BIT
        0x3024 /*EGL_RED_SIZE*/, 8,
        0x3023 /*EGL_GREEN_SIZE*/, 8,
        0x3022 /*EGL_BLUE_SIZE*/, 8,
        0x3021 /*EGL_ALPHA_SIZE*/, 8,
        0x3025 /*EGL_DEPTH_SIZE*/, 0,
        0x3026 /*EGL_STENCIL_SIZE*/, 0,
        EGL10.EGL_NONE
    };
    int[] count = new int[1];
    EGLConfig[] cfg = new EGLConfig[1];
    if (!egl.eglChooseConfig(eglDisplay, spec, cfg, 1, count) || count[0] == 0) {
      throw new IllegalArgumentException("eglChooseConfig failed: " + GLUtils.getEGLErrorString(egl.eglGetError()));
    }
    return cfg[0];
  }

  public void onDispose() {
    // Make current to delete GL resources deterministically
    egl.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext);
    GLES20.glDeleteTextures(3, mTextures, 0);
    GLES20.glDeleteBuffers(1, ebo, 0);
    GLES20.glDeleteBuffers(1, vbo, 0);
    GLES30.glDeleteVertexArrays(1, vao, 0);
    deinitGL();
  }

  // ---- helpers ----
  private static int compile(int type, String src) {
    int sh = GLES20.glCreateShader(type);
    GLES20.glShaderSource(sh, src);
    GLES20.glCompileShader(sh);
    int[] ok = new int[1];
    GLES20.glGetShaderiv(sh, GLES20.GL_COMPILE_STATUS, ok, 0);
    if (ok[0] == 0) {
      String log = GLES20.glGetShaderInfoLog(sh);
      GLES20.glDeleteShader(sh);
      throw new RuntimeException("Shader compile failed: " + log + "\n" + src);
    }
    return sh;
  }
}
