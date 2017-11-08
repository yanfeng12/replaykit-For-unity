
using System;
using System.Collections;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using UnityEngine;
using UnityEngine.UI;

public class NewBehaviourScript : MonoBehaviour {

    Button _start;
    Button _stop;
    Button _share;
    // Use this for initialization
    void Start () {
        _start = this.transform.Find("Start").GetComponent<Button>();
        _stop = this.transform.Find("Stop").GetComponent<Button>();
        _share = this.transform.Find("Share").GetComponent<Button>();

        _start.onClick.AddListener(StartVideo);
        _stop.onClick.AddListener(StopVideo);
		_share.onClick.AddListener (ShareVideo);      

    }


    private void StopVideo()
    {
#if UNITY_ANDROID
        ShareREC.StopRecorder();
#elif UNITY_IOS
        StopV();
#endif      
    }
    [DllImport("__Internal")]
	public static extern void StopV();
    [DllImport("__Internal")]
	public static extern void StartV();
    [DllImport("__Internal")]
	public static extern void SharaV();
    private void ShareVideo()
    {
#if UNITY_ANDROID
        ShareREC.ShowShare();
#elif UNITY_IOS
		StartV();
#endif    
    }

    private void StartVideo()
    {
#if UNITY_ANDROID
        ShareREC.StartRecorder();
#elif UNITY_IOS
        StartV();
#endif    
    }
	[DllImport("__Internal")]
	private static extern void unityToIOS (string str);

	void OnGUI()
	{
		// 当点击按钮后，调用外部方法
		if (GUI.Button (new Rect (300, 300, 300, 100), "跳转到IOS界面")) {
			// Unity调用ios函数，同时传递数据
			unityToIOS ("Hello IOS");
		}
	}

    // Update is called once per frame
    void Update () {
		
	}
	int count = 0;
	//在这里OC的代码通知U3D截屏
	void StartScreenshot(string str)
	{
		Application.CaptureScreenshot(count +"u3d.JPG");
		count++;
	}
}
