package com.jci.mediaprocessor.media_processor;

import android.graphics.SurfaceTexture;
import android.opengl.GLES20;
import android.opengl.GLUtils;
import android.util.Log;
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

public abstract class BaseRenderer {
  static { System.loadLibrary("MediaProcessor"); }

  public static native byte[] getBuffer(long ptr, int size);

  protected static final String LOG_TAG = "OpenGL.Worker";

  // Either texture OR surface will be set, not both
  protected final SurfaceTexture texture;
  protected volatile Surface surface;      // may be replaced by SurfaceProducer
  private volatile Surface pendingSurface; // set by SurfaceProducer.Callback

  protected volatile boolean surfaceLost = false;

  protected int width;
  protected int height;

  protected EGL10 egl;
  protected EGLDisplay eglDisplay;
  protected EGLContext eglContext;
  protected EGLSurface eglSurface;
  protected EGLConfig eglConfig;

  protected int mProgramHandle;

  protected final int[] mTextures = new int[3];
  protected int mPositionHandle;
  protected final int[] mYUVTextureHandle = new int[3];

  // simple VBO/EBO handles (ES2-safe; no VAOs)
  private final int[] vbo = new int[1];
  private final int[] ebo = new int[1];

  // ---- NEW: SW path via SurfaceProducer ----
  public BaseRenderer(Surface surface, int width, int height) {
    this.surface = surface;
    this.texture = null;
    this.width = width;
    this.height = height;
  }

  // ---- Legacy: SW path via SurfaceTextureEntry ----
  public BaseRenderer(SurfaceTexture texture, int width, int height) {
    this.texture = texture;
    this.surface = null;
    this.width = width;
    this.height = height;
  }

  // abstract bits unchanged
  protected abstract String vertexShader();
  protected abstract String fragmentShader();
  protected abstract void connectTexturesToProgram();
  protected abstract void loadTexture(ByteBuffer[] buffers);
  protected abstract void drawTexture();

  public abstract void setBuffer(byte[] inY, byte[] inU, byte[] inV);
  public abstract void setBufferPtr(long ptr, int size);

  // ---------- GL / EGL init ----------
  public synchronized void initGL() {
    egl = (EGL10) EGLContext.getEGL();
    eglDisplay = egl.eglGetDisplay(EGL10.EGL_DEFAULT_DISPLAY);
    if (eglDisplay == EGL10.EGL_NO_DISPLAY)
      throw new RuntimeException("eglGetDisplay failed");

    int[] version = new int[2];
    if (!egl.eglInitialize(eglDisplay, version))
      throw new RuntimeException("eglInitialize failed");

    eglConfig = chooseEglConfig();
    eglContext = createContext(egl, eglDisplay, eglConfig);

    // Create initial window surface from either Surface OR SurfaceTexture
    final Object win = (surface != null) ? surface : texture;
    createOrRecreateWindowSurface(win);

    GLES20.glGenTextures(3, mTextures, 0);
  }

  public synchronized void initShaders() {
    int vertexShaderHandle = GLES20.glCreateShader(GLES20.GL_VERTEX_SHADER);
    if (vertexShaderHandle != 0) {
      GLES20.glShaderSource(vertexShaderHandle, vertexShader());
      GLES20.glCompileShader(vertexShaderHandle);
      int[] status = new int[1];
      GLES20.glGetShaderiv(vertexShaderHandle, GLES20.GL_COMPILE_STATUS, status, 0);
      if (status[0] == 0) {
        Log.e(LOG_TAG, "Vertex shader compile error");
        GLES20.glDeleteShader(vertexShaderHandle);
        vertexShaderHandle = 0;
      }
    }
    if (vertexShaderHandle == 0)
      throw new RuntimeException("Error creating vertex shader.");

    int fragmentShaderHandle = GLES20.glCreateShader(GLES20.GL_FRAGMENT_SHADER);
    if (fragmentShaderHandle != 0) {
      GLES20.glShaderSource(fragmentShaderHandle, fragmentShader());
      GLES20.glCompileShader(fragmentShaderHandle);
      int[] status = new int[1];
      GLES20.glGetShaderiv(fragmentShaderHandle, GLES20.GL_COMPILE_STATUS, status, 0);
      if (status[0] == 0) {
        Log.e(LOG_TAG, "Fragment shader compile error");
        GLES20.glDeleteShader(fragmentShaderHandle);
        fragmentShaderHandle = 0;
      }
    }
    if (fragmentShaderHandle == 0)
      throw new RuntimeException("Error creating fragment shader.");

    mProgramHandle = GLES20.glCreateProgram();
    if (mProgramHandle != 0) {
      GLES20.glAttachShader(mProgramHandle, vertexShaderHandle);
      GLES20.glAttachShader(mProgramHandle, fragmentShaderHandle);
      GLES20.glBindAttribLocation(mProgramHandle, 0, "a_Position");
      GLES20.glBindAttribLocation(mProgramHandle, 1, "a_TexCoordinate");
      GLES20.glLinkProgram(mProgramHandle);
      int[] link = new int[1];
      GLES20.glGetProgramiv(mProgramHandle, GLES20.GL_LINK_STATUS, link, 0);
      if (link[0] == 0) {
        GLES20.glDeleteProgram(mProgramHandle);
        mProgramHandle = 0;
      }
    } else {
      throw new RuntimeException("Error creating program.");
    }

    mPositionHandle = GLES20.glGetAttribLocation(mProgramHandle, "a_Position");
    connectTexturesToProgram();
    GLES20.glUseProgram(mProgramHandle);
  }

  public synchronized void initBuffers() {
    // Corrected: 4 floats/vertex (x,y,u,v); stride = 4 * sizeof(float). ES2-only (no VAOs).
    float[] vertices = {
      // x,   y,   u,   v
       1f,  1f,  1f,  1f,
       1f, -1f,  1f,  0f,
      -1f, -1f,  0f,  0f,
      -1f,  1f,  0f,  1f
    };
    int[] indices = { 0, 1, 2, 0, 2, 3 };

    FloatBuffer vBuf = ByteBuffer.allocateDirect(vertices.length * Float.BYTES)
        .order(ByteOrder.nativeOrder()).asFloatBuffer().put(vertices);
    vBuf.position(0);
    IntBuffer iBuf = ByteBuffer.allocateDirect(indices.length * Integer.BYTES)
        .order(ByteOrder.nativeOrder()).asIntBuffer().put(indices);
    iBuf.position(0);

    GLES20.glGenBuffers(1, vbo, 0);
    GLES20.glGenBuffers(1, ebo, 0);

    GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, vbo[0]);
    GLES20.glBufferData(GLES20.GL_ARRAY_BUFFER, vertices.length * Float.BYTES, vBuf, GLES20.GL_STATIC_DRAW);

    GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, ebo[0]);
    GLES20.glBufferData(GLES20.GL_ELEMENT_ARRAY_BUFFER, indices.length * Integer.BYTES, iBuf, GLES20.GL_STATIC_DRAW);

    final int stride = 4 * Float.BYTES;
    GLES20.glVertexAttribPointer(0, 2, GLES20.GL_FLOAT, false, stride, 0);
    GLES20.glEnableVertexAttribArray(0);
    GLES20.glVertexAttribPointer(1, 2, GLES20.GL_FLOAT, false, stride, 2 * Float.BYTES);
    GLES20.glEnableVertexAttribArray(1);

    // leave buffers bound (fine for this simple quad)
  }

  // ---------- SurfaceProducer callbacks bridge ----------
  public synchronized void notifySurfaceCleanup() {
    surfaceLost = true;
    // unbind old surface from context to avoid swapping to it
    if (egl != null && eglDisplay != null && eglContext != null) {
      egl.eglMakeCurrent(eglDisplay, EGL10.EGL_NO_SURFACE, EGL10.EGL_NO_SURFACE, eglContext);
    }
  }

  public synchronized void notifySurfaceAvailable(Surface newSurface) {
    // Don't recreate here (callback thread may differ from GL thread). Just store.
    this.pendingSurface = newSurface;
    this.surfaceLost = false;
  }

  // ---------- Draw helpers ----------
  protected synchronized void ensureSurfaceIfNeeded() {
    if (surfaceLost) return; // wait until onSurfaceAvailable delivers a new one
    if (pendingSurface != null) {
      // (Re)create against the new Surface
      createOrRecreateWindowSurface(pendingSurface);
      pendingSurface = null;
    } else if (eglSurface == null || eglSurface == EGL10.EGL_NO_SURFACE) {
      // First-time creation path (may happen if SurfaceTexture ctor was used)
      final Object win = (surface != null) ? surface : texture;
      createOrRecreateWindowSurface(win);
    }
  }

  protected synchronized boolean swapBuffers() {
    if (eglDisplay == null || eglSurface == null || eglSurface == EGL10.EGL_NO_SURFACE) return false;
    if (!egl.eglSwapBuffers(eglDisplay, eglSurface)) {
      int err = egl.eglGetError();
      if (err == EGL10.EGL_BAD_SURFACE) { // 0x300D = 12301
        Log.w(LOG_TAG, "eglSwapBuffers: EGL_BAD_SURFACE (12301) — waiting for new Surface");
        surfaceLost = true;
        return false;
      }
      Log.e(LOG_TAG, "eglSwapBuffers error: " + err);
      return false;
    }
    return true;
  }

  private void createOrRecreateWindowSurface(Object nativeWindow) {
    if (eglSurface != null && eglSurface != EGL10.EGL_NO_SURFACE) {
      egl.eglDestroySurface(eglDisplay, eglSurface);
      eglSurface = null;
    }
    eglSurface = egl.eglCreateWindowSurface(eglDisplay, eglConfig, nativeWindow, null);
    if (eglSurface == null || eglSurface == EGL10.EGL_NO_SURFACE) {
      throw new RuntimeException("eglCreateWindowSurface failed: " + GLUtils.getEGLErrorString(egl.eglGetError()));
    }
    if (!egl.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
      throw new RuntimeException("eglMakeCurrent error: " + GLUtils.getEGLErrorString(egl.eglGetError()));
    }
  }

  protected synchronized void deinitGL() {
    if (egl == null) return;
    egl.eglMakeCurrent(eglDisplay, EGL10.EGL_NO_SURFACE, EGL10.EGL_NO_SURFACE, EGL10.EGL_NO_CONTEXT);
    if (eglSurface != null && eglSurface != EGL10.EGL_NO_SURFACE) {
      egl.eglDestroySurface(eglDisplay, eglSurface);
      eglSurface = null;
    }
    if (eglContext != null && eglContext != EGL10.EGL_NO_CONTEXT) {
      egl.eglDestroyContext(eglDisplay, eglContext);
      eglContext = null;
    }
    if (eglDisplay != null && eglDisplay != EGL10.EGL_NO_DISPLAY) {
      egl.eglTerminate(eglDisplay);
      eglDisplay = null;
    }
  }

  protected EGLContext createContext(EGL10 egl, EGLDisplay display, EGLConfig cfg) {
    // ES2 context (VAOs are not core here; keep ES2-safe rendering) 
    int[] attrib = { 0x3098 /*EGL_CONTEXT_CLIENT_VERSION*/, 2, EGL10.EGL_NONE };
    return egl.eglCreateContext(display, cfg, EGL10.EGL_NO_CONTEXT, attrib);
  }

  protected EGLConfig chooseEglConfig() {
    int[] spec = new int[] {
      0x3040/*EGL_RENDERABLE_TYPE*/, 4, // EGL_OPENGL_ES2_BIT
      0x3024/*EGL_RED_SIZE*/,      8,
      0x3023/*EGL_GREEN_SIZE*/,    8,
      0x3022/*EGL_BLUE_SIZE*/,     8,
      0x3021/*EGL_ALPHA_SIZE*/,    8,
      0x3025/*EGL_DEPTH_SIZE*/,    0,
      0x3026/*EGL_STENCIL_SIZE*/,  0,
      EGL10.EGL_NONE
    };
    int[] count = new int[1];
    EGLConfig[] cfg = new EGLConfig[1];
    if (!egl.eglChooseConfig(eglDisplay, spec, cfg, 1, count) || count[0] == 0) {
      throw new IllegalArgumentException("Failed to choose config: " + GLUtils.getEGLErrorString(egl.eglGetError()));
    }
    return cfg[0];
  }

  public synchronized void onDispose() {
    // Make context current so deletes are valid
    if (egl != null && eglDisplay != null && eglContext != null && eglSurface != null) {
      egl.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext);
    }
    GLES20.glDeleteTextures(3, mTextures, 0);
    if (vbo[0] != 0) GLES20.glDeleteBuffers(1, vbo, 0);
    if (ebo[0] != 0) GLES20.glDeleteBuffers(1, ebo, 0);
    deinitGL();
  }
}
